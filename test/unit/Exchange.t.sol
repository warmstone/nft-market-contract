// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {LibOrder} from "../../src/libraries/LibOrder.sol";
import {LibSignature} from "../../src/libraries/LibSignature.sol";
import {NonceManager} from "../../src/NonceManager.sol";
import {Exchange} from "../../src/Exchange.sol";
import {MockERC721} from "../mocks/MockERC721.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockProtocolManager} from "../mocks/MockProtocolManager.sol";

contract ExchangeTest is Test {
    Exchange exchange;
    MockERC721 nft;
    MockERC20 weth;
    MockProtocolManager pm;

    uint256 constant MAKER_KEY = 0xabc123;
    uint256 constant TAKER_KEY = 0xdef456;
    address maker;
    address taker;
    address feeRecipient = address(0xFEE);

    function setUp() public {
        maker = vm.addr(MAKER_KEY);
        taker = vm.addr(TAKER_KEY);

        nft = new MockERC721("Test", "TST");
        weth = new MockERC20("WETH", "WETH");
        pm = new MockProtocolManager();
        pm.setPaymentTokenAllowed(address(weth), true);

        Exchange impl = new Exchange();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        exchange = Exchange(address(proxy));
        exchange.initialize(address(pm), address(0), address(0), address(this));

        vm.deal(taker, 10 ether);
    }

    function _signOrder(LibOrder.Order memory order, uint256 key) internal view returns (bytes memory) {
        bytes32 digest = LibSignature.getTypedDataHash(order, address(exchange));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _validSellOrder(uint256 tokenId) internal view returns (LibOrder.Order memory) {
        return LibOrder.Order({
            maker: maker,
            taker: address(0),
            side: LibOrder.OrderSide.Sell,
            kind: LibOrder.OrderKind.FixedPrice,
            assetType: LibOrder.AssetType.ERC721,
            collection: address(nft),
            tokenId: tokenId,
            amount: 1,
            paymentToken: address(0),
            price: 1 ether,
            startPrice: 1 ether,
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + 1 days),
            salt: uint256(keccak256(abi.encodePacked(tokenId))),
            counter: 0,
            extra: bytes32(0)
        });
    }

    // --- fulfillOrder (Sell: maker sells NFT, taker pays ETH) ---

    function test_FulfillOrder_ETH() public {
        uint256 tokenId = nft.mint(maker);
        vm.prank(maker);
        nft.approve(address(exchange), tokenId);

        LibOrder.Order memory order = _validSellOrder(tokenId);
        order.salt = 1;
        bytes memory sig = _signOrder(order, MAKER_KEY);

        vm.prank(taker);
        exchange.fulfillOrder{value: 1 ether}(order, sig);

        assertEq(nft.ownerOf(tokenId), taker);
        assertEq(address(feeRecipient).balance, 0.005 ether);
    }

    function test_FulfillOrder_ETHExcessRefund() public {
        uint256 tokenId = nft.mint(maker);
        vm.prank(maker);
        nft.approve(address(exchange), tokenId);

        LibOrder.Order memory order = _validSellOrder(tokenId);
        order.salt = 2;
        bytes memory sig = _signOrder(order, MAKER_KEY);

        uint256 balanceBefore = taker.balance;
        vm.prank(taker);
        exchange.fulfillOrder{value: 2 ether}(order, sig);

        assertEq(nft.ownerOf(tokenId), taker);
        assertEq(taker.balance, balanceBefore - 1 ether);
    }

    // --- acceptOffer (Buy: maker buys NFT, taker sends NFT, maker pays WETH) ---

    function test_AcceptOffer_WETH() public {
        uint256 tokenId = nft.mint(taker);
        vm.prank(taker);
        nft.approve(address(exchange), tokenId);

        weth.mint(maker, 1 ether);
        vm.prank(maker);
        weth.approve(address(exchange), 1 ether);

        LibOrder.Order memory order = _buyOrder(tokenId);
        bytes memory sig = _signOrder(order, MAKER_KEY);

        vm.prank(taker);
        exchange.acceptOffer(order, sig, tokenId);

        assertEq(nft.ownerOf(tokenId), maker);
        assertEq(weth.balanceOf(taker), 1 ether - 0.005 ether);
    }

    // --- Double-fill protection ---

    function test_FulfillOrder_RevertsDoubleFill() public {
        uint256 tokenId = nft.mint(maker);
        vm.prank(maker);
        nft.approve(address(exchange), tokenId);

        LibOrder.Order memory order = _validSellOrder(tokenId);
        order.salt = 3;
        bytes memory sig = _signOrder(order, MAKER_KEY);

        vm.prank(taker);
        exchange.fulfillOrder{value: 1 ether}(order, sig);

        vm.prank(taker);
        vm.expectRevert(NonceManager.OrderAlreadyFilled.selector);
        exchange.fulfillOrder{value: 1 ether}(order, sig);
    }

    // --- Batch ---

    function test_FulfillBatch() public {
        uint256 tokenId1 = nft.mint(maker);
        uint256 tokenId2 = nft.mint(maker);
        vm.prank(maker);
        nft.setApprovalForAll(address(exchange), true);

        LibOrder.Order[] memory orders = new LibOrder.Order[](2);
        bytes[] memory sigs = new bytes[](2);
        uint256[] memory takerTokenIds = new uint256[](2);
        orders[0] = _validSellOrder(tokenId1);
        orders[1] = _validSellOrder(tokenId2);
        orders[0].salt = 4;
        orders[1].salt = 5;
        takerTokenIds[0] = tokenId1;
        takerTokenIds[1] = tokenId2;
        sigs[0] = _signOrder(orders[0], MAKER_KEY);
        sigs[1] = _signOrder(orders[1], MAKER_KEY);

        vm.prank(taker);
        exchange.fulfillBatch{value: 2 ether}(orders, sigs, takerTokenIds);

        assertEq(nft.ownerOf(tokenId1), taker);
        assertEq(nft.ownerOf(tokenId2), taker);
    }

    // --- UUPS: scheduleUpgrade ---

    function test_ScheduleUpgrade() public {
        assertEq(exchange.upgradeScheduled(), 0);
        exchange.scheduleUpgrade();
        assertGt(exchange.upgradeScheduled(), 0);
    }

    function test_ScheduleUpgrade_RevertsNonOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0xBEEF)));
        exchange.scheduleUpgrade();
    }

    // --- Pause ---

    function test_Paused_PreventsTrade() public {
        uint256 tokenId = nft.mint(maker);
        vm.prank(maker);
        nft.approve(address(exchange), tokenId);

        exchange.pause();

        LibOrder.Order memory order = _validSellOrder(tokenId);
        order.salt = 6;
        bytes memory sig = _signOrder(order, MAKER_KEY);
        vm.prank(taker);
        vm.expectRevert();
        exchange.fulfillOrder{value: 1 ether}(order, sig);
    }

    // --- Insufficient allowance ---

    function test_AcceptOffer_RevertsInsufficientAllowance() public {
        uint256 tokenId = nft.mint(taker);
        vm.prank(taker);
        nft.approve(address(exchange), tokenId);

        weth.mint(maker, 1 ether);
        // maker does NOT approve Exchange for WETH

        LibOrder.Order memory order = _buyOrder(tokenId);
        bytes memory sig = _signOrder(order, MAKER_KEY);

        vm.prank(taker);
        vm.expectRevert(Exchange.InsufficientAllowance.selector);
        exchange.acceptOffer(order, sig, tokenId);
    }

    // --- Mixed batch ---

    function test_FulfillBatch_MixedBuyAndSell() public {
        // Sell order: maker sells tokenA to taker for ETH
        uint256 tokenA = nft.mint(maker);
        vm.prank(maker);
        nft.approve(address(exchange), tokenA);

        // Buy order: taker sells tokenB to maker for WETH
        uint256 tokenB = nft.mint(taker);
        vm.prank(taker);
        nft.approve(address(exchange), tokenB);

        weth.mint(maker, 1 ether);
        vm.prank(maker);
        weth.approve(address(exchange), 1 ether);

        LibOrder.Order[] memory orders = new LibOrder.Order[](2);
        bytes[] memory sigs = new bytes[](2);
        uint256[] memory takerTokenIds = new uint256[](2);

        orders[0] = _validSellOrder(tokenA);
        orders[0].salt = 10;
        takerTokenIds[0] = tokenA;

        orders[1] = _buyOrder(tokenB);
        orders[1].salt = 11;
        takerTokenIds[1] = tokenB;

        sigs[0] = _signOrder(orders[0], MAKER_KEY);
        sigs[1] = _signOrder(orders[1], MAKER_KEY);

        vm.prank(taker);
        exchange.fulfillBatch{value: 1 ether}(orders, sigs, takerTokenIds);

        // taker received tokenA (from sell order)
        assertEq(nft.ownerOf(tokenA), taker);
        // maker received tokenB (from buy order)
        assertEq(nft.ownerOf(tokenB), maker);
        // taker received WETH for tokenB
        assertEq(weth.balanceOf(taker), 1 ether - 0.005 ether);
    }

    function test_FulfillBatch_ExcessETHRefund() public {
        uint256 tokenId = nft.mint(maker);
        vm.prank(maker);
        nft.approve(address(exchange), tokenId);

        LibOrder.Order[] memory orders = new LibOrder.Order[](1);
        bytes[] memory sigs = new bytes[](1);
        uint256[] memory takerTokenIds = new uint256[](1);
        orders[0] = _validSellOrder(tokenId);
        orders[0].salt = 12;
        takerTokenIds[0] = tokenId;
        sigs[0] = _signOrder(orders[0], MAKER_KEY);

        uint256 balanceBefore = taker.balance;
        vm.prank(taker);
        exchange.fulfillBatch{value: 2 ether}(orders, sigs, takerTokenIds);

        assertEq(taker.balance, balanceBefore - 1 ether);
    }

    // --- Payment token whitelist ---

    function test_FulfillOrder_RevertsUnsupportedPaymentToken() public {
        uint256 tokenId = nft.mint(maker);
        vm.prank(maker);
        nft.approve(address(exchange), tokenId);

        LibOrder.Order memory order = _validSellOrder(tokenId);
        order.salt = 13;
        order.paymentToken = address(0xBADC0FFEE);
        bytes memory sig = _signOrder(order, MAKER_KEY);

        vm.prank(taker);
        vm.expectRevert(Exchange.UnsupportedPaymentToken.selector);
        exchange.fulfillOrder{value: 1 ether}(order, sig);
    }

    function test_AcceptOffer_ERC20Sell() public {
        // Sell order denominated in WETH: maker sells NFT, taker pays via WETH
        uint256 tokenId = nft.mint(maker);
        vm.prank(maker);
        nft.approve(address(exchange), tokenId);

        weth.mint(taker, 1 ether);
        vm.prank(taker);
        weth.approve(address(exchange), 1 ether);

        LibOrder.Order memory order = _validSellOrder(tokenId);
        order.salt = 14;
        order.paymentToken = address(weth);
        bytes memory sig = _signOrder(order, MAKER_KEY);

        vm.prank(taker);
        exchange.fulfillOrder(order, sig);

        assertEq(nft.ownerOf(tokenId), taker);
        assertEq(weth.balanceOf(maker), 1 ether - 0.005 ether);
    }

    // --- UUPS timelock enforcement ---

    function test_UpgradeTimelock_RevertsNotScheduled() public {
        Exchange newImpl = new Exchange();
        vm.expectRevert(Exchange.UpgradeNotScheduled.selector);
        exchange.upgradeToAndCall(address(newImpl), "");
    }

    function test_UpgradeTimelock_RevertsNotExpired() public {
        Exchange newImpl = new Exchange();
        exchange.scheduleUpgrade();
        vm.expectRevert(Exchange.TimelockNotExpired.selector);
        exchange.upgradeToAndCall(address(newImpl), "");
    }

    function test_UpgradeTimelock_Expired() public {
        Exchange newImpl = new Exchange();
        exchange.scheduleUpgrade();
        vm.warp(block.timestamp + 48 hours + 1);
        exchange.upgradeToAndCall(address(newImpl), "");
        // after successful upgrade, the proxy should delegate to new impl
        // basic sanity: owner unchanged
        assertEq(exchange.owner(), address(this));
    }

    // --- Wrong side ---

    function test_FulfillOrder_RevertsBuySide() public {
        uint256 tokenId = nft.mint(taker);
        LibOrder.Order memory order = _buyOrder(tokenId);
        bytes memory sig = _signOrder(order, MAKER_KEY);
        vm.prank(taker);
        vm.expectRevert(Exchange.WrongSide.selector);
        exchange.fulfillOrder{value: 1 ether}(order, sig);
    }

    // --- Helpers ---

    function _buyOrder(uint256 tokenId) internal view returns (LibOrder.Order memory) {
        return LibOrder.Order({
            maker: maker,
            taker: address(0),
            side: LibOrder.OrderSide.Buy,
            kind: LibOrder.OrderKind.FixedPrice,
            assetType: LibOrder.AssetType.ERC721,
            collection: address(nft),
            tokenId: tokenId,
            amount: 1,
            paymentToken: address(weth),
            price: 1 ether,
            startPrice: 1 ether,
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + 1 days),
            salt: uint256(keccak256(abi.encodePacked(tokenId, "buy"))),
            counter: 0,
            extra: bytes32(0)
        });
    }
}
