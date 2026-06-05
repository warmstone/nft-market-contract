# NFT Signed Order DEX 合约设计方案（最新版）

## 概述

基于 EIP-712 链下签名订单的 NFT 去中心化交易所。Maker 链下签名订单（零 Gas 挂单），Taker 链上提交签名并结算。Go 后端维护可搜索订单簿、元数据、撮合视图和 API，合约层只处理必须去信任化的部分：签名验证、防重放、NFT 转移、资金结算、版税分配。

v1 支持：固定价卖单、WETH 单品报价、EIP-712 签名订单、基础协议费、EIP-2981 版税、订单取消与批量作废。

后续扩展：集合出价、荷兰拍卖、EIP-1271 合约钱包、ERC1155、TraitBid、Bundle。

---

## 1. 合约架构

```
contracts/
  Exchange.sol              // 主入口（UUPS，可升级）
  OrderValidator.sol         // 内部模块/抽象合约：订单字段 + 签名 + 时效 + taker + 状态校验
  NonceManager.sol           // 内部模块/抽象合约：订单取消 + 防重放
  PaymentProcessor.sol       // 内部模块/抽象合约：ETH/ERC20 收付款 + 协议费 + 版税分配
  ProtocolManager.sol        // 配置模块：协议费率、收费地址、支付代币白名单、operator 角色
  RoyaltyManager.sol         // 配置模块：EIP-2981 版税查询 + fallback 手动注册
  CollectionManager.sol      // 配置模块：collection 白名单/黑名单、交易开关
  libraries/
    LibOrder.sol             // 订单结构 + hash 构建
    LibSignature.sol         // EIP-712 + ECDSA + EIP-1271
    LibTransfer.sol          // ETH/ERC20/ERC721 安全转账
    LibFee.sol               // 费用计算
  interfaces/
    IExchange.sol
    IERC2981.sol
    IERC721Minimal.sol
```

### 模块职责

| 合约 | 职责 |
|---|---|
| `Exchange.sol` | 对外入口：`fulfillOrder` / `acceptOffer` / `fulfillBatch` / `cancel` / `incrementCounter`，负责串联校验、记账和结算 |
| `OrderValidator.sol` | 校验：签名恢复、maker/taker、时效、counter、cancelled、filled、collection 合法性 |
| `NonceManager.sol` | 取消管理：按 maker + salt 取消、按 orderHash 取消、counter 递增作废。单订单取消 + 全量作废两级 |
| `PaymentProcessor.sol` | 资金流转：从买家收款 → 分配协议费 → 分配版税 → 支付卖家。支持 ETH + ERC20 |
| `ProtocolManager.sol` | 协议配置：protocolFeeBPS、feeRecipient、paymentToken 白名单、operator 角色 |
| `RoyaltyManager.sol` | 版税：EIP-2981 标准查询 → fallback 手动注册。支持版税上限 |
| `CollectionManager.sol` | collection 管控：allowlist / blocklist |

### 继承结构

```solidity
contract Exchange is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    // v1 中校验、取消、防重放、payment 作为内部模块/抽象合约集成，减少跨合约调用复杂度。
    // 可独立配置或未来升级频繁的模块通过接口组合。
    IProtocolManager  public protocolManager;
    IRoyaltyManager   public royaltyManager;
    ICollectionManager public collectionManager;
}
```

v1 推荐只让 `Exchange` 使用 UUPS。`OrderValidator`、`NonceManager`、`PaymentProcessor` 作为内部模块/抽象合约集成到 `Exchange`，避免第一版出现过多代理、跨合约调用和权限同步问题。

`ProtocolManager`、`RoyaltyManager`、`CollectionManager` 可以按配置复杂度选择独立合约或内部模块。如果独立部署，地址由 `Exchange` 持有，升级权限由 owner 多签控制，建议加 48 小时 timelock。

### 合约间关系

```
Exchange (主入口, UUPS)
  ├── OrderValidator (内部模块/抽象合约)
  ├── NonceManager (内部模块/抽象合约)
  ├── PaymentProcessor (内部模块/抽象合约)
  ├── ProtocolManager (配置模块，可独立合约)
  ├── RoyaltyManager (配置模块，可独立合约)
  └── CollectionManager (配置模块，可独立合约)
```

---

## 2. 订单数据模型

```solidity
enum OrderSide { Sell, Buy }

enum AssetType { ERC721, ERC1155 }

enum OrderKind {
    FixedPrice,
    DutchAuction,
    CollectionBid,
    TraitBid,       // 预留
    Bundle          // 预留
}

struct Order {
    address maker;           // 签名者
    address taker;           // address(0) = 公开订单；非零 = 私密订单（指定 taker）
    OrderSide side;          // Sell: maker 卖 NFT / Buy: maker 买 NFT
    OrderKind kind;          // 订单类型
    AssetType assetType;     // ERC721 起，预留 ERC1155
    address collection;      // NFT 合约地址
    uint256 tokenId;         // FixedPrice / item offer 时为具体 tokenId；CollectionBid 时该字段不参与成交 token 选择
    uint256 amount;          // ERC721 = 1，ERC1155 >= 1
    address paymentToken;    // address(0) = ETH，否则为 ERC20
    uint128 price;           // FixedPrice: 成交价 / DutchAuction: 结束价（底价）
    uint128 startPrice;      // DutchAuction: 起始价，非荷兰拍时 == price
    uint64 startTime;        // 订单生效时间
    uint64 endTime;          // 过期时间，0 = 永不过期
    uint256 salt;            // 订单唯一标识，用于取消和 filled 标记
    uint256 counter;         // maker 维度递增，用于全量作废
    bytes32 extra;           // Merkle root / trait proof / bundle hash（扩展预留）
}
```

### 字段规则

| 字段 | 规则 |
|---|---|
| `maker` | 必须等于签名恢复地址 |
| `taker` | address(0) 表示公开订单，非零时仅指定 taker 可成交 |
| `side` | Sell = maker 卖 NFT；Buy = maker 买 NFT |
| `kind` | v1 支持 FixedPrice；DutchAuction / CollectionBid 后续扩展 |
| `assetType` | v1 仅 ERC721，结构预留 ERC1155 |
| `tokenId` | FixedPrice / item offer 必须是具体 tokenId；CollectionBid 扩展中忽略该字段，taker 通过 calldata 指定实际 tokenId |
| `paymentToken` | address(0) = ETH，否则为 ProtocolManager 白名单中的 ERC20 |
| `price` | FixedPrice 即成交价；DutchAuction 即结束价 |
| `startPrice` | DutchAuction 起始价，要求 startPrice > price |
| `startTime/endTime` | 定义有效窗口，endTime == 0 永不过期 |
| `salt` | maker 维度唯一订单盐值，用于单订单取消；由前端/后端生成并校验唯一性 |
| `counter` | maker 递增此值作废所有旧 counter 订单 |
| `extra` | 预留：Merkle root（trait bid 证明）、bundle hash 等 |

### 为什么要 salt

`salt` 作为 maker 维度下的订单唯一标识，用于精确取消某一个签名订单。前端/后端必须保证同一 maker 不复用 salt，否则 `cancel(salt)` 会取消该 maker 名下所有相同 salt 的签名订单。

订单是否已成交由 `orderHash` 标记，避免重复成交；`counter` 负责全量作废，递增后所有低于当前 counter 的旧订单失效。

v1 不再单独维护 `usedNonces`，避免 `salt / nonce / counter` 三套机制语义重叠。订单唯一性由完整 `orderHash` 保证。

---

## 3. 签名方案

### EIP-712 Domain

```solidity
struct EIP712Domain {
    string name;                // "NFTMarketExchange"
    string version;             // "1"
    uint256 chainId;
    address verifyingContract;  // Exchange proxy 地址
}
```

### TypeHash

```solidity
bytes32 constant ORDER_TYPEHASH = keccak256(
    "Order(address maker,address taker,uint8 side,uint8 kind,uint8 assetType,address collection,uint256 tokenId,uint256 amount,address paymentToken,uint128 price,uint128 startPrice,uint64 startTime,uint64 endTime,uint256 salt,uint256 counter,bytes32 extra)"
);
```

### ECDSA + EIP-1271

`LibSignature.sol` 封装签名验证逻辑：

```solidity
library LibSignature {
    function verify(Order memory order, bytes memory signature) internal view {
        bytes32 hash = LibOrder.hash(order);

        if (order.maker.code.length == 0) {
            // EOA: ECDSA
            address signer = ECDSA.recover(hash, signature);
            require(signer == order.maker, InvalidSignature());
        } else {
            // 合约钱包: EIP-1271
            require(
                IERC1271(order.maker).isValidSignature(hash, signature) == 0x1626ba7e,
                InvalidERC1271Signature()
            );
        }
    }
}
```

- EOA 用 OpenZeppelin `ECDSA.recover`（内部校验 s 值，防可锻造性）
- 合约钱包用 `order.maker` 调用 EIP-1271 `isValidSignature`（支持 Gnosis Safe、ERC-4337 智能账户），不要把 signer 额外编码进 signature
- domain separator 缓存，避免每次重算
- v1 可以先交付 EOA ECDSA，EIP-1271 作为 Milestone 5 扩展；如果开发排期允许，也可以提前实现但不阻塞 v1 验收。

---

## 4. 防重放与取消

NonceManager 负责所有取消和重放保护。

```solidity
// maker 维度按 salt 取消，避免不同 maker 使用相同 salt 时互相影响
mapping(address => mapping(uint256 => bool)) public cancelledSalt;

// 全量作废：maker → 当前有效 counter 值
mapping(address => uint256) public minCounter;

// 成交记录：orderHash → 是否已成交
mapping(bytes32 => bool) public filled;
```

### 取消操作

```solidity
// 1. 按 maker + salt 取消单个订单
function cancel(uint256 salt) external {
    require(!cancelledSalt[msg.sender][salt], AlreadyCancelled());
    cancelledSalt[msg.sender][salt] = true;
    emit OrderCancelled(msg.sender, salt);
}

// 2. 批量取消
function cancel(uint256[] calldata salts) external {
    for (uint256 i = 0; i < salts.length; ++i) {
        if (!cancelledSalt[msg.sender][salts[i]]) {
            cancelledSalt[msg.sender][salts[i]] = true;
            emit OrderCancelled(msg.sender, salts[i]);
        }
    }
}

// 3. 递增 counter，作废所有旧订单
function incrementCounter() external {
    minCounter[msg.sender]++;
    emit CounterIncremented(msg.sender, minCounter[msg.sender]);
}
```

### 执行时校验

```text
cancelledSalt[order.maker][order.salt] == false
order.counter >= minCounter[order.maker]
filled[orderHash] == false
```

---

## 5. 撮合结算流程

### 5.1 买家接受签名卖单

Seller 链下签名 Sell 订单 → 后端存储 → Buyer 调用 `fulfillOrder(order, signature)` 附付款。

```
验证:
  1. LibSignature.verify(order, signature) → signer
  2. signer == order.maker
  3. order.taker == address(0) || order.taker == msg.sender
  4. block.timestamp ∈ [startTime, endTime] (endTime == 0 跳过)
  5. cancelledSalt[order.maker][order.salt] == false
  6. order.counter >= minCounter[order.maker]
  7. filled[orderHash] == false
  8. collectionManager 校验 collection 合法
  9. protocolManager 校验 paymentToken 在白名单

定价:
 10. finalPrice = LibOrder.getPrice(order)  // v1 仅 FixedPrice

支付:
 11. filled[orderHash] = true    // 先记账

转账:
 12. PaymentProcessor 分配: 协议费 → 版税 → maker
     → ETH 场景校验 msg.value，ERC20 场景从 buyer(msg.sender) 收款 finalPrice
     → 扣除协议费 → protocolFeeRecipient
     → 扣除版税 → creator
     → 剩余 → maker(seller)
 13. IERC721(order.collection).safeTransferFrom(maker, msg.sender, order.tokenId)
 14. emit OrderFulfilled(...)
```

### 5.2 卖家接受签名买单

Buyer 链下签名 Buy 订单（WETH） → 后端存储 → Seller 调用 `acceptOffer(order, signature, takerTokenId)`。

```
验证:
  1-9. 同 5.1（taker 校验同）
 10. 校验 WETH allowance: IERC20(paymentToken).allowance(maker, Exchange) >= finalPrice

转账:
 11. 标记 filled[orderHash] = true
 12. PaymentProcessor.settleOffer(order, finalPrice, msg.sender)
     → 从 maker(buyer) 转 WETH 到 PaymentProcessor
     → 扣除协议费 → protocolFeeRecipient
     → 扣除版税 → creator
     → 剩余 → msg.sender(seller)
 13. IERC721(order.collection).safeTransferFrom(msg.sender, maker, takerTokenId)
 14. emit OrderFulfilled(...)
```

**为什么买单用 WETH 而非预存款**：WETH + allowance 是行业标准（OpenSea/Blur/LooksRare），用户只需一次 approve 即可对任意多数量的 collection 出价，资金效率远高于每个订单预存 ETH。

### 5.3 集合出价（CollectionBid）

> 后续扩展能力，不进入 v1 必交付范围。

`order.kind == CollectionBid` 时，订单中的 `tokenId` 不参与成交 token 选择，taker 传入 `takerTokenId` 指定实际成交 token。

```solidity
function acceptOffer(
    Order calldata order,
    bytes calldata signature,
    uint256 takerTokenId  // taker 指定自己卖的 token
) external {
    if (order.kind == OrderKind.CollectionBid) {
        // CollectionBid 不要求 order.tokenId == 0，避免与真实 tokenId=0 冲突。
        // 实际成交 tokenId 由 takerTokenId 提供。
    } else {
        require(takerTokenId == order.tokenId, "tokenId mismatch");
    }
    // ... 其余流程同 5.2
}
```

### 5.4 批量成交

```solidity
function fulfillBatch(
    Order[] calldata orders,
    bytes[] calldata signatures
) external payable {
    for (uint256 i = 0; i < orders.length; ++i) {
        _fulfillSingle(orders[i], signatures[i]);
    }
    // 退还多余 ETH
    if (msg.value > totalSpent) _safeTransferETH(msg.sender, msg.value - totalSpent);
}
```

首个版本每条订单独立验证，任一失败全部 revert。后续可加 `revertOnFail` 参数支持部分成交。

---

## 6. 荷兰拍卖定价

> 后续扩展能力，不进入 v1 必交付范围。

```solidity
function getPrice(Order memory order) internal view returns (uint128) {
    if (order.kind != OrderKind.DutchAuction) return order.price;
    if (block.timestamp >= order.endTime) return order.price;

    uint256 elapsed = block.timestamp - order.startTime;
    uint256 duration = order.endTime - order.startTime;
    uint256 drop = uint256(order.startPrice - order.price) * elapsed / duration;
    return order.startPrice - uint128(drop);
}
```

线性衰减：startPrice → price，持续 startTime → endTime。

**约束**：`startPrice > price`、`endTime > startTime`。

**抢跑风险**：荷兰拍价格随时间降低，公开 mempool 中的交易会被 MEV 抢跑。推荐 taker 使用 Flashbots/MEV-protect 提交成交交易。合约层面不做特殊处理（这是 MEV 层的问题）。

---

## 7. 支付与费用

### 支付代币

| paymentToken | 行为 |
|---|---|
| `address(0)` | 原生 ETH（仅用于 fulfillOrder 买单场景） |
| ERC20 白名单 | WETH、USDC 等（用于 acceptOffer 买单场景 + 未来扩展） |

白名单由 ProtocolManager 管理：
```solidity
mapping(address => bool) public paymentTokenAllowed;

function setPaymentTokenAllowed(address token, bool allowed) external onlyOperator;
```

### 费用分配

对于成交价 `P`：

```text
protocolFee = P * protocolFeeBps / 10_000
royaltyFee  = min(IERC2981.royaltyInfo(), royaltyCap)
sellerAmount = P - protocolFee - royaltyFee
```

分配顺序：协议费 → 版税 → 卖家。

```solidity
function _settlePayment(
    Order memory order,
    uint128 price,
    address payer,
    address seller,
    uint256 ethAvailable
) internal returns (uint256 ethSpent) {
    uint256 protocolFee = price * protocolManager.protocolFeeBps() / 10000;
    (address royaltyReceiver, uint256 royaltyFee) = royaltyManager.getRoyalty(
        order.collection, order.tokenId, price
    );
    require(protocolFee + royaltyFee <= price, FeeExceedsPrice());

    // 1. 收款
    if (order.paymentToken == address(0)) {
        require(ethAvailable >= price, InsufficientPayment());
        ethSpent = price;
    } else {
        IERC20(order.paymentToken).safeTransferFrom(payer, address(this), price);
    }

    // 2. 协议费
    if (protocolFee > 0) _transfer(protocolManager.feeRecipient(), protocolFee, order.paymentToken);

    // 3. 版税
    if (royaltyFee > 0) _transfer(royaltyReceiver, royaltyFee, order.paymentToken);

    // 4. 卖家
    _transfer(seller, price - protocolFee - royaltyFee, order.paymentToken);
}
```

ETH 与 ERC20 必须分支处理：

- `paymentToken == address(0)`：使用 `msg.value` 作为付款来源，批量购买时累计 `ethSpent`，函数结束后统一退还 `msg.value - totalEthSpent`。
- `paymentToken != address(0)`：使用 `SafeERC20.safeTransferFrom(payer, address(this), price)` 拉取 ERC20，再按费用分账。

### 参数与限制

```solidity
uint128 public protocolFeeBPS = 50;        // 默认 0.5%
uint128 public constant MAX_PROTOCOL_BPS = 500;   // 最高 5%
uint128 public constant MAX_ROYALTY_BPS  = 1000;  // 最高 10%
```

---

## 8. 版税管理（RoyaltyManager）

```solidity
interface IERC2981 is IERC165 {
    function royaltyInfo(uint256 tokenId, uint256 salePrice)
        external view returns (address receiver, uint256 royaltyAmount);
}
```

### 查询逻辑

```solidity
function getRoyalty(address collection, uint256 tokenId, uint256 price)
    external view returns (address receiver, uint256 amount)
{
    // 1. 先安全检测 collection 是否支持 EIP-2981。
    // 推荐使用 OpenZeppelin ERC165Checker，或用 staticcall/try-catch 包住 supportsInterface。
    bool supports2981 = ERC165Checker.supportsInterface(collection, 0x2a55205a);

    if (supports2981) {
        try IERC2981(collection).royaltyInfo(tokenId, price) returns (address r, uint256 a) {
            if (r != address(0) && a > 0) {
                uint256 maxRoyalty = price * MAX_ROYALTY_BPS / 10000;
                return (r, a > maxRoyalty ? maxRoyalty : a);
            }
        } catch {}
    }

    // 2. fallback: 管理员手动注册
    uint96 bps = manualRoyaltyBPS[collection];
    if (bps == 0) return (address(0), 0);
    return (manualReceiver[collection], price * bps / 10000);
}
```

三层防护：
- 用 `ERC165Checker` 或 `staticcall/try-catch` 安全检测 `supportsInterface`，避免恶意 collection 在 ERC165 查询阶段 revert
- `try/catch` 包裹，防止恶意 collection 在 `royaltyInfo` 中 revert 阻塞交易
- 版税上限兜底，防止异常 collection 报出超出成交价的版税

---

## 9. Collection 与支付管控

`CollectionManager`:
```solidity
mapping(address => bool) public collectionAllowed;
mapping(address => bool) public collectionBlocked;

function setCollectionAllowed(address collection, bool allowed) external onlyOperator;
function setCollectionBlocked(address collection, bool blocked) external onlyOperator;
```

`ProtocolManager`:
```solidity
mapping(address => bool) public paymentTokenAllowed;
address public feeRecipient;
uint128 public protocolFeeBPS;
address public operator;  // 与 owner 分离的运营角色

function setPaymentTokenAllowed(address token, bool allowed) external onlyOperator;
function setProtocolFeeBPS(uint128 bps) external onlyOwner;
function setFeeRecipient(address recipient) external onlyOwner;
function setOperator(address op) external onlyOwner;
```

---

## 10. 事件（后端索引）

```solidity
event OrderFulfilled(
    bytes32 indexed orderHash,
    uint256 indexed salt,
    address indexed maker,
    address taker,
    address seller,
    address buyer,
    OrderSide side,
    OrderKind kind,
    address collection,
    uint256 tokenId,
    uint256 amount,
    address paymentToken,
    uint128 finalPrice,
    uint256 protocolFee,
    uint256 royaltyFee
);

event OrderCancelled(address indexed maker, uint256 indexed salt);
event CounterIncremented(address indexed maker, uint256 newCounter);
event ProtocolFeeUpdated(address setter, uint128 oldBPS, uint128 newBPS);
event FeeRecipientUpdated(address oldRecipient, address newRecipient);
event PaymentTokenUpdated(address token, bool allowed);
event CollectionUpdated(address collection, bool allowed, bool blocked);
event OperatorUpdated(address oldOperator, address newOperator);
```

Go 后端完全通过事件同步状态，无需查询合约 storage。

`seller` 和 `buyer` 显式写入事件，避免后端每次都通过 `maker/taker + side` 推导交易双方，降低索引和排错成本。

---

## 11. 安全设计

### 必须实现

- `nonReentrant` on `fulfillOrder` / `acceptOffer` / `fulfillBatch`
- EIP-712 domain 绑定 chainId + verifyingContract
- ECDSA 签名验证；EIP-1271 合约钱包签名验证作为扩展能力
- OpenZeppelin ECDSA 防签名可锻造性（s 值低半区校验）
- strict orderHash/counter/salt 三重防重放
- startTime/endTime 时效校验
- taker 匹配校验（私密订单）
- collection blocklist 校验
- payment token whitelist 校验
- ETH 超额退款
- safe ERC721 transfer（含 onERC721Received 回调）
- ERC20 返回值处理（SafeERC20）
- protocol fee cap
- royalty cap
- try/catch 版税查询防 revert
- Pausable 紧急暂停（仅影响成交，不影响取消/提现）

### 转账顺序（先记账后转账）

```text
1. 验证订单 + 签名
2. 标记 filled[orderHash]
3. 资金结算
4. NFT 转移（safeTransferFrom 会回调 taker）
5. emit 事件
```

确保状态变更在外部调用（safeTransferFrom）之前完成，防重入。

### 权限分离

```text
owner (多签):         升级合约、设置费率、设置 feeRecipient、设置 operator
operator (后端服务):   管理 collection 白名单/黑名单、管理 payment token 白名单
feeRecipient (财库):   接收协议费
```

---

## 12. 升级治理

```text
owner 多签 (Gnosis Safe)
  └── 发起升级
        ├── 48h timelock → 用户窗口期内可 cancel 或停止 NFT/ERC20 授权
        └── UUPS upgradeTo
```

- UUPS 模式：逻辑合约含升级函数，代理轻量
- `_authorizeUpgrade` 仅 owner
- timelock 确保用户有退出窗口
- v1 仅 `Exchange` 使用 UUPS；配置类模块如果独立部署，再单独评估是否需要 UUPS

---

## 13. Gas 预估

| 操作 | 预估 Gas |
|---|---|
| fulfillOrder (ETH, FixedPrice) | ~95K |
| acceptOffer (WETH) | ~90K |
| cancel (单个 salt) | ~30K |
| cancel (批量 10 个) | ~50K |
| incrementCounter | ~25K |

后续扩展预估：

| 操作 | 预估 Gas |
|---|---|
| fulfillOrder (ETH, DutchAuction) | ~100K |
| acceptCollectionBid (WETH) | ~95K |

---

## 14. 错误码

```solidity
// 签名
error InvalidSignature();
error InvalidERC1271Signature();

// 时效
error OrderExpired();
error OrderNotStarted();

// 状态
error OrderCancelled();
error AlreadyCancelled();
error OrderAlreadyFilled();
error CounterTooLow();

// taker
error WrongTaker();

// 金额
error InsufficientPayment();
error InsufficientAllowance();
error FeeExceedsPrice();
error InvalidPrice();

// token
error UnsupportedPaymentToken();
error UnsupportedAssetType();

// collection
error CollectionBlocked();

// 转账
error ETHTransferFailed();
error ERC20TransferFailed();

// 权限
error NotOwner();
error NotOperator();
error ZeroAddress();
```

---

## 15. 测试计划

### 单元测试

- **签名**: EOA ECDSA 有效签名 / 无效签名 / 签名可锻造性（高 s 值应 revert）/ chainId 不同的签名应 reject；EIP-1271 放入扩展测试
- **订单验证**: 过期 / 未到 startTime / taker 不匹配 / maker 不匹配 / paymentToken 非白名单 / collection 被 block
- **取消与防重放**: 按 maker + salt 取消 / 批量取消 / incrementCounter / 取消后不可成交 / 已成交不可再成交 / 相同 orderHash 重放 reject / counter 过低 reject / A 取消 salt=N 不影响 B 的 salt=N
- **成交-Sell**: ETH 固定价买入 / ETH 超额退款 / ERC20 买入
- **成交-Buy**: WETH 单品报价被接受 / allowance 不足 reject
- **费用**: 协议费计算 / 版税 EIP-2981 / 版税 fallback manual / 版税 + 协议费 > price revert / try-catch 异常 collection / supportsInterface 不支持时跳过 / supportsInterface revert 时不阻塞交易
- **安全**: 重入保护（mock 恶意 ERC721 回调）/ Pausable / 非 owner 操作 revert / 非 operator 操作 revert
- **批量**: 批量成交全成功 / 任一失败全 revert

### 集成测试

- E2E: maker 签名 → Go 服务存储 → taker 链上执行 → NFT/ETH/WETH 正确分配
- Mock EIP-2981 + 版税 → creator 正确收款
- 3 collection × 5 订单并发 → 状态无交叉污染
- UUPS 升级 → storage 保持

### Gas 报告

Foundry `forge test --gas-report` 完整输出。

---

## 16. v1 交付清单

### 合约文件

| 文件 | 类型 | 说明 |
|---|---|---|
| `Exchange.sol` | UUPS 可升级 | 主入口，继承 OrderValidator + NonceManager + PaymentProcessor 抽象合约 |
| `OrderValidator.sol` | 抽象合约 | 签名恢复、maker/taker/时效/counter/cancelled/filled/collection 校验 |
| `NonceManager.sol` | 抽象合约 | cancelledSalt + minCounter + filled 管理；按 salt 取消、批量取消、incrementCounter |
| `PaymentProcessor.sol` | 抽象合约 | ETH/ERC20 收款 + 协议费/版税/卖家分配 |
| `RoyaltyManager.sol` | Ownable 非升级 | EIP-2981 版税查询 + fallback 手动注册 |
| `ProtocolManager.sol` | Ownable 非升级 | protocolFeeBPS、feeRecipient、paymentToken 白名单、operator |
| `CollectionManager.sol` | Ownable 非升级 | collection allowlist / blocklist |
| `LibOrder.sol` | library | Order 结构体 + orderHash 构建 |
| `LibSignature.sol` | library | EIP-712 hash + ECDSA 签名验证 |
| `LibTransfer.sol` | library | ETH/ERC20/ERC721 安全转账 |
| `LibFee.sol` | library | 费用计算 |

### v1 验收标准

- [ ] seller 链下 EIP-712 签名 FixedPrice sell 订单 → buyer 用 ETH 调用 `fulfillOrder` → NFT 转给 buyer、ETH 转给 seller（扣除费用）
- [ ] buyer 链下 EIP-712 签名 FixedPrice buy 订单（WETH）→ seller 调用 `acceptOffer` → NFT 转给 buyer、WETH 转给 seller（扣除费用）
- [ ] `cancel(salt)` 后该 salt 订单不可成交；`incrementCounter()` 后所有旧 counter 订单不可成交
- [ ] 同一 maker 不复用 salt；A 取消 salt=N 不影响 B 的 salt=N
- [ ] 同一 orderHash 不可重复成交
- [ ] 协议费 + EIP-2981 版税正确分配，事件包含费用明细
- [ ] collection blocklist / paymentToken whitelist 生效
- [ ] Pausable 暂停/恢复成交功能
- [ ] UUPS 升级流程正常，存储状态保持
- [ ] 全部单元测试通过 + Gas 报告输出

---

## 17. v1 范围

```text
Must have:
  ✓ EIP-712 signed fixed-price sell orders
  ✓ EIP-712 signed WETH buy offers
  ✓ ERC721 settlement
  ✓ ETH + WETH payment
  ✓ ECDSA signature verification
  ✓ salt-based single cancellation + counter bulk invalidation
  ✓ protocol fee (0.5% default, capped at 5%)
  ✓ EIP-2981 royalty with supportsInterface + try/catch
  ✓ collection allowlist/blocklist
  ✓ events for Go backend indexing
  ✓ Exchange UUPS upgradeable with timelock
  ✓ Pausable
  ✓ Gas report

Can wait:
  ✓ EIP-1271 smart wallet signature verification
  ✓ Dutch auction sell orders
  ✓ ERC1155 (结构已预留)
  ✓ CollectionBid + TraitBid (结构已预留 extra 字段)
  ✓ Bundle order
  ✓ English auction
  ✓ Lending
```
