import "jetton.tolk"

global admin: slice;
global firstJettonMasterAddress: slice;
global firstJettonWalletCode: cell;
global firstAmount: int;
global secondJettonMasterAddress: slice;
global secondJettonWalletCode: cell;
global secondAmount: int;

@inline
fun loadData() {
    var data = getContractData().beginParse();
    admin = data.loadAddress();
    firstJettonMasterAddress = data.loadAddress();
    firstJettonWalletCode = data.loadRef();
    firstAmount = data.loadCoins();
    secondJettonMasterAddress = data.loadAddress();
    secondJettonWalletCode = data.loadRef();
    secondAmount = data.loadCoins();
}

@inline
fun saveData() {
    var data = beginCell()
        .storeSlice(admin)
        .storeSlice(firstJettonMasterAddress)
        .storeRef(firstJettonWalletCode)
        .storeCoins(firstAmount)
        .storeSlice(secondJettonMasterAddress)
        .storeRef(secondJettonWalletCode)
        .storeCoins(secondAmount)
        .endCell();
    setContractData(data);
}

@inline
fun cashback(address: slice, query_id: int) {
    val message = beginCell()
        .storeUint(0x18, 6)
        .storeSlice(address)
        .storeCoins(0)
        .storeUint(0, 1 + 4 + 4 + 64 + 32 + 1 + 1)
        .storeBuilder(beginCell().storeUint(query_id, 64))
        .endCell();
    sendRawMessage(message, 64);
}

@inline
fun makeJettonMessage(jetton_master: slice, jetton_wallet_code: cell, destination: slice, forward_destination: slice, amount: int, query_id: int, ton_amount: int) {
    val jetton_transfer = beginCell()
        .storeUint(OPCODE_JETTON_TRANSFER, 32)
        .storeUint(query_id, 64)
        .storeCoins(amount)
        .storeSlice(destination)
        .storeSlice(forward_destination)
        .storeUint(0, 1)
        .storeCoins(1)
        .storeUint(0, 1)
        .endCell();
    val message = beginCell()
        .storeUint(0x18, 6)
        .storeSlice(calculateUserJettonWalletAddress(getMyAddress(), jetton_master, jetton_wallet_code))
        .storeCoins(ton_amount)
        .storeUint(0, 1 + 4 + 4 + 64 + 32 + 1)
        .storeUint(1, 1)
        .storeRef(jetton_transfer)
        .endCell();
    return message;
}

@inline
fun sendJetton(jetton_master: slice, jetton_wallet_code: cell, destination: slice, amount: int, query_id: int) {
    val message = makeJettonMessage(jetton_master, jetton_wallet_code, destination, getMyAddress(), amount, query_id, 0);
    sendRawMessage(message, 64 + 1);
}

@inline
fun sendJettonWithTON(jetton_master: slice, jetton_wallet_code: cell, destination: slice, amount: int, query_id: int, ton_amount: int) {
    val message = makeJettonMessage(jetton_master, jetton_wallet_code, destination, destination, amount, query_id, ton_amount);
    sendRawMessage(message, 0);
}

const JETTON_NOTIFY = 0x7362d09c;
const OPCODE_JETTON_TRANSFER = 0x0f8a7ea5;

const OPCODE_EXCHANGE = 0x2458d1c9;
const OPCODE_ADD_LIQUID = 0x01a631c9;

const OPCODE_DESTROY = 0x00000015;

@inline
fun equalJettonAddress(address: slice, jettonMasterAddress:slice, jettonWalletCode:cell): bool {
    return isSliceBitsEqual(address, calculateUserJettonWalletAddress(getMyAddress(), jettonMasterAddress, jettonWalletCode));
}

@inline
fun isFromFirstJetton(source: slice): bool {
    return equalJettonAddress(source, firstJettonMasterAddress, firstJettonWalletCode);
}

@inline
fun isFromSecondJetton(source: slice): bool {
    return equalJettonAddress(source, secondJettonMasterAddress, secondJettonWalletCode);
}

@inline
fun calculateConstantProduct(x: int, y: int, dx: int): int {
    return dx * y / (x + dx);
}

fun onNotify(source: slice, query_id: int, address: slice, amount: int, body: slice) {
    if (body.isEndOfSlice()) {
        return;
    }
    var op = body.loadUint(32);
    if (op == OPCODE_EXCHANGE) {
        if (isFromFirstJetton(source)) {
            val result = calculateConstantProduct(firstAmount, secondAmount, amount);
            firstAmount += amount;
            secondAmount -= result;
            sendJetton(secondJettonMasterAddress, secondJettonWalletCode, address, result, query_id);
            saveData();
        } else if (isFromSecondJetton(source)) {
            val result = calculateConstantProduct(secondAmount, firstAmount, amount);
            secondAmount += amount;
            firstAmount -= result;
            sendJetton(firstJettonMasterAddress, firstJettonWalletCode, address, result, query_id);
            saveData();
        }
    }
    if (op == OPCODE_ADD_LIQUID) {
        if (isFromFirstJetton(source)) {
            firstAmount += amount;
            saveData();
        } else if (isFromSecondJetton(source)) {
            secondAmount += amount;
            saveData();
        }
    }
}

fun destroy(destination: slice) {
    val message = beginCell()
        .storeUint(0x18, 6)
        .storeSlice(destination)
        .storeCoins(0)
        .storeUint(0, 1 + 4 + 4 + 64 + 32 + 1 + 1)
        .endCell();
    sendRawMessage(message, 128 + 32);
}

fun onInternalMessage(myBalance: int, msgValue: int, msgFull: cell, msgBody: slice) {
    if (msgBody.isEndOfSlice()) {
        return;
    }
    var cs = msgFull.beginParse();
    var flags = cs.loadUint(4);
    if (flags & 1) {
        return;
    }
    var source = cs.loadAddress();
    // Check if notify from jetton transfer
    loadData();
    var op = msgBody.loadUint(32);
    if (op == JETTON_NOTIFY) {
        var query_id = msgBody.loadUint(64);
        var amount = msgBody.loadCoins();
        var sender = msgBody.loadAddress();
        var is_ref = msgBody.loadUint(1);
        var body = is_ref ? msgBody.loadRef().beginParse() : msgBody;
        onNotify(source, query_id, sender, amount, body);
    }
    if (op == OPCODE_DESTROY && admin.isSliceBitsEqual(source)) {
        sendJettonWithTON(firstJettonMasterAddress, firstJettonWalletCode, source, firstAmount, 0, msgValue / 2 - 10);
        sendJettonWithTON(secondJettonMasterAddress, secondJettonWalletCode, source, secondAmount, 0, msgValue / 2 - 10);
        destroy(source);
    }
}

get pool(): (slice, slice, cell, int, slice, cell, int) {
    loadData();
    return (admin, firstJettonMasterAddress, firstJettonWalletCode, firstAmount, secondJettonMasterAddress, secondJettonWalletCode, secondAmount);
}