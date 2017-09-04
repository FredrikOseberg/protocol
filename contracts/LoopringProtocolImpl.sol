/*

  Copyright 2017 Loopring Project Ltd (Loopring Foundation).

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

  http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.

*/
pragma solidity ^0.4.11;

import "zeppelin-solidity/contracts/token/ERC20.sol";
import "zeppelin-solidity/contracts/math/Math.sol";
import "zeppelin-solidity/contracts/math/SafeMath.sol";

import "./utils/ArrayUtil.sol";
import "./utils/UintUtil.sol";
import "./TokenRegistry.sol";
import "./LoopringProtocol.sol";
import "./LoopringFingerprintRegistry.sol";

/// @title Loopring Token Exchange Protocol Implementation Contract v1
/// @author Daniel Wang - <daniel@loopring.org>,
/// @author Kongliang Zhong - <kongliang@loopring.org>
contract LoopringProtocolImpl is LoopringProtocol {
    using SafeMath  for uint;
    using Math      for uint;
    using ArrayUtil for uint;
    using UintUtil  for uint;


    ////////////////////////////////////////////////////////////////////////////
    /// Variables                                                            ///
    ////////////////////////////////////////////////////////////////////////////

    address public  lrcTokenAddress             = address(0);
    address public  tokenRegistryContract       = address(0);
    address public  fingerprintRegistryContract = address(0);
    uint    public  maxRingSize                 = 0;
    uint    public  ringIndex                   = 0;
    uint    public  maxPriceRateDeviation       = 0;

    /// The following two maps are used to keep order fill and cancellation
    /// historical records.
    mapping (bytes32 => uint) public filled;
    mapping (bytes32 => uint) public cancelled;


    ////////////////////////////////////////////////////////////////////////////
    /// Structs                                                              ///
    ////////////////////////////////////////////////////////////////////////////

    /// @param order        The original order
    /// @param owner        This order owner's address. This value is calculated.
    /// @param savingShareelection -
    ///                     A miner-supplied value indicating if LRC (value = 0)
    ///                     or saving share is choosen by the miner (value = 1).
    ///                     We may support more fee model in the future.
    /// @param fillAmountS  Amount of tokenS to sell, calculated by protocol.
    /// @param rateAmountS  This value is initially provided by miner and is
    ///                     calculated by based on the original information of
    ///                     all orders of the order-ring, in other orders, this
    ///                     value is independent of the order's current state.
    ///                     This value and `rateAmountB` can be used to calculate
    ///                     the proposed exchange rate calculated by miner.
    /// @param lrcReward    The amount of LRC paid by miner to order owner in
    ///                     exchange for sharing-share.
    /// @param lrcFee       The amount of LR paid by order owner to miner.
    /// @param savingShare  TokenS paid to miner, as the fee of this order and
    ///                     next order, calculated by protocol.
    struct OrderState {
        Order   order;
        bytes32 orderHash;
        address owner;
        uint8   savingShareelection;
        uint    rateAmountS;
        uint    availableAmountS;
        uint    fillAmountS;
        uint    lrcReward;
        uint    lrcFee;
        uint    savingShare;
    }

    struct Ring {
        bytes32      ringHash;
        OrderState[] orders;
        address      miner;
        address      feeRecepient;
        bool         throwIfLRCIsInsuffcient;
    }


    ////////////////////////////////////////////////////////////////////////////
    /// Evemts                                                               ///
    ////////////////////////////////////////////////////////////////////////////

    event RingMined(
        uint                _ringIndex,
        uint                _blocknumber,
        bytes32     indexed _ringHash,
        address     indexed _miner,
        address     indexed _feeRecepient,
        bool                _fingerprintFound);

    event OrderFilled(
        uint                _ringIndex,
        uint                _blocknumber,
        bytes32     indexed _orderHash,
        uint                _amountS,
        uint                _amountB,
        uint                _lrcReward,
        uint                _lrcFee);

    event Exception(string message);


    ////////////////////////////////////////////////////////////////////////////
    /// Constructor                                                          ///
    ////////////////////////////////////////////////////////////////////////////

    function LoopringProtocolImpl(
        address _lrcTokenAddress,
        address _tokenRegistryContract,
        address _fingerprintRegistryContract,
        uint    _maxRingSize,
        uint    _maxPriceRateDeviation
        )
        public {

        require(address(0) != _lrcTokenAddress);
        require(address(0) != _tokenRegistryContract);
        require(_maxRingSize >= 2);
        require(_maxPriceRateDeviation >= 1);

        lrcTokenAddress             = _lrcTokenAddress;
        tokenRegistryContract       = _tokenRegistryContract;
        fingerprintRegistryContract = _fingerprintRegistryContract;
        maxRingSize                 = _maxRingSize;
        maxPriceRateDeviation       = _maxPriceRateDeviation;
    }

    ////////////////////////////////////////////////////////////////////////////
    /// Public Functions                                                     ///
    ////////////////////////////////////////////////////////////////////////////

    /// @dev Submit a order-ring for validation and settlement.
    /// @param tokenSList   List of each order's tokenS. Note that next order's
    ///                     `tokenS` equals this order's `tokenB`.
    /// @param uintArgsList List of uint-type arguments in this order:
    ///                     amountS,AmountB,rateAmountS,expiration,rand,lrcFee.
    /// @param uint8ArgsList -
    ///                     List of unit8-type arguments, in this order:
    ///                     savingSharePercentageList,savingShareelectionList.
    /// @param vList        List of v for each order. This list is 1-larger than
    ///                     the previous lists, with the last element being the
    ///                     v value of the ring signature.
    /// @param rList        List of r for each order. This list is 1-larger than
    ///                     the previous lists, with the last element being the
    ///                     r value of the ring signature.
    /// @param sList        List of s for each order. This list is 1-larger than
    ///                     the previous lists, with the last element being the
    ///                     s value of the ring signature.
    /// @param feeRecepient The recepient address for fee collection. If this is
    ///                     '0x0', all fees will be paid to the address who had
    ///                     signed this transaction, not `msg.sender`. Noted if
    ///                     LRC need to be paid back to order owner as the result
    ///                     of fee selection model, LRC will also be sent from
    ///                     this address.
    /// @param throwIfLRCIsInsuffcient -
    ///                     If true, throw exception if any order's spendable
    ///                     LRC amount is smaller than requried; if false, ring-
    ///                     minor will give up collection the LRC fee.
    function submitRing(
        address[]   tokenSList,
        uint[6][]   uintArgsList,
        uint8[2][]  uint8ArgsList,
        bool[]      buyNoMoreThanAmountBList,
        uint8[]     vList,
        bytes32[]   rList,
        bytes32[]   sList,
        address     feeRecepient,
        bool        throwIfLRCIsInsuffcient
        )
        public {

        // Check ring size
        uint ringSize = tokenSList.length;
        check(ringSize > 1 && ringSize <= maxRingSize, "invalid ring size");

        verifyInputDataIntegrity(
            ringSize,
            tokenSList,
            uintArgsList,
            uint8ArgsList,
            buyNoMoreThanAmountBList,
            vList,
            rList,
            sList);

        verifyTokensRegistered(tokenSList);

        bytes32 ringHash = LoopringFingerprintRegistry(fingerprintRegistryContract).getRingHash(
            ringSize,
            feeRecepient,
            throwIfLRCIsInsuffcient,
            vList,
            rList,
            sList
        );

        address minerAddress = calculateSignerAddress(
            ringHash,
            vList[ringSize],
            rList[ringSize],
            sList[ringSize]
        );

        // Assemble input data into a struct so we can pass it to functions.
        var orders = assembleOrders(
            ringSize,
            tokenSList,
            uintArgsList,
            uint8ArgsList,
            buyNoMoreThanAmountBList,
            vList,
            rList,
            sList);

        if (feeRecepient == address(0)) {
            feeRecepient = minerAddress;
        }

        var ring = Ring(
            ringHash,
            orders,
            minerAddress,
            feeRecepient,
            throwIfLRCIsInsuffcient);

        // Do the hard work.
        verifyRingHasNoSubRing(ringSize, ring);

        processRing(ringSize, ring);

        settleRing(ringSize, ring);
    }

    /// @dev Cancel a order. cancel amount(amountS or amountB) can be specified
    ///      in orderValues.
    /// @param tokenAddresses     tokenS,tokenB
    /// @param orderValues        amountS, amountB, expiration, rand, lrcFee,
    ///                           and cancelAmount
    /// @param buyNoMoreThanAmountB -
    ///                           If true, this order does not accept buying
    ///                           more than `amountB`.
    /// @param savingSharePercentage -
    ///                           The percentage of savings paid to miner.
    /// @param v                  Order ECDSA signature parameter v.
    /// @param r                  Order ECDSA signature parameters r.
    /// @param s                  Order ECDSA signature parameters s.
    function cancelOrder(
        address[2] tokenAddresses,
        uint[7]    orderValues,
        bool       buyNoMoreThanAmountB,
        uint8      savingSharePercentage,
        uint8      v,
        bytes32    r,
        bytes32    s
        )
        public {

        uint cancelAmount = orderValues[5];
        check(cancelAmount > 0, "amount to cancel is zero");

        var order = Order(
            tokenAddresses[0],
            tokenAddresses[1],
            orderValues[0],
            orderValues[1],
            orderValues[2],
            orderValues[3],
            orderValues[4],
            buyNoMoreThanAmountB,
            savingSharePercentage,
            v,
            r,
            s
        );

        bytes32 orderHash = calculateOrderHash(order);
        cancelled[orderHash] = cancelled[orderHash].add(cancelAmount);
    }

    ////////////////////////////////////////////////////////////////////////////
    /// Internal & Private Functions                                         ///
    ////////////////////////////////////////////////////////////////////////////

    /// @dev Validate a ring.
    function verifyRingHasNoSubRing(
        uint ringSize,
        Ring ring
        )
        internal
        constant {

        // Check the ring has no sub-ring.
        for (uint i = 0; i < ringSize -1; i++) {
            address tokenS = ring.orders[i].order.tokenS;
            for (uint j = i + 1; j < ringSize; j++){
                 check(tokenS != ring.orders[j].order.tokenS, "found sub-ring");
            }
        }
    }

    function verifyTokensRegistered(address[] tokens) internal constant {
        var registryContract = TokenRegistry(tokenRegistryContract);
        for (uint i = 0; i < tokens.length; i++) {
            check(registryContract.isTokenRegistered(tokens[i]),
                "token not registered");
        }
    }

    function processRing(uint ringSize, Ring ring) internal constant {
        // Exchange rates calculation are performed by ring-miners as solidity
        // cannot get power-of-1/n operation, therefore we have to verify
        // these rates are correct.
        verifyMinerSuppliedFillRates(ringSize, ring);


        // Scale down each order independently by substracting amount-filled and
        // amount-cancelled. Order owner's current balance and allowance are
        // not taken into consideration in these operations.
        scaleRingBasedOnHistoricalRecords(ringSize, ring);

        // Based on the already verified exchange rate provided by ring-miners,
        // we can furthur scale down orders based on token balance and allowance,
        // then find the smallest order of the ring, then calculate each order's
        // `fillAmountS`.
        calculateRingFillAmount(ringSize, ring);

        // Calculate each order's `lrcFee` and `lrcRewrard` and splict how much
        // of `fillAmountS` shall be paid to matching order or miner as saving-
        // share.
        calculateRingFees(ringSize, ring);
    }

    function settleRing(
        uint ringSize,
        Ring ring
        )
        internal {

        for (uint i = 0; i < ringSize; i++) {
            var state = ring.orders[i];
            var prev = ring.orders[i.prev(ringSize)];
            var next = ring.orders[i.next(ringSize)];

            // Pay tokenS to previous order, or to miner as previous order's
            // saving share or/and this order's saving share.
            var tokenS = ERC20(state.order.tokenS);
            if (prev.order.buyNoMoreThanAmountB) {
                tokenS.transferFrom(
                    state.owner,
                    prev.owner,
                    state.fillAmountS);
            } else {
                tokenS.transferFrom(
                    state.owner,
                    prev.owner,
                    state.fillAmountS - prev.savingShare);

                if (prev.savingShare > 0) {
                    tokenS.transferFrom(
                        state.owner,
                        ring.feeRecepient,
                        prev.savingShare);
                }
            }

            if (state.order.buyNoMoreThanAmountB) {
                if (state.savingShare > 0) {
                    tokenS.transferFrom(
                        state.owner,
                        ring.feeRecepient,
                        state.savingShare);
                }
            }

            // Pay LRC
            var lrc = ERC20(lrcTokenAddress);
            if (state.lrcReward > 0) {
                lrc.transferFrom(
                    ring.feeRecepient,
                    state.owner,
                    state.lrcReward);
            }

            if (state.lrcFee > 0) {
                lrc.transferFrom(
                    state.owner,
                    ring.feeRecepient,
                    state.lrcFee);
            }

            // Update fill records
            if (state.order.buyNoMoreThanAmountB) {
                filled[state.orderHash] += next.fillAmountS;
            } else {
                filled[state.orderHash] += state.fillAmountS;
            }

            // TODO(daniel): currently this event doesn't reflect how much
            // EXCACTLY an order gets or pays.
            OrderFilled(
                ringIndex,
                block.number,
                state.orderHash,
                state.fillAmountS,
                next.fillAmountS,
                state.lrcReward,
                state.lrcFee
                );
        }

        RingMined(
            ringIndex,
            block.number,
            ring.ringHash,
            ring.miner,
            ring.feeRecepient,
            false //TODO(kongliang): update this
            );
        ringIndex++;
    }

    function verifyMinerSuppliedFillRates(
        uint ringSize,
        Ring ring
        )
        internal
        constant {

        var orders = ring.orders;
        uint[] memory priceSavingRateList = new uint[](ringSize);
        uint savingRateSum = 0;

        for (uint i = 0; i < ringSize; i++) {
            uint rateAmountB = orders[i.next(ringSize)].rateAmountS;
            uint s0b1 = orders[i].order.amountS.mul(rateAmountB);
            uint b0s1 = orders[i].rateAmountS.mul(orders[i].order.amountB);

            check(s0b1 >= b0s1, "miner supplied exchange rate is invalid");

            //TODO(kongliang): Make `10000` a constant.
            priceSavingRateList[i] = s0b1.sub(b0s1).mul(10000).div(s0b1);
            savingRateSum += priceSavingRateList[i];
        }

        uint savingRateAvg = savingRateSum.div(ringSize);
        uint variance = caculateVariance(priceSavingRateList, savingRateAvg);

        check(variance <= maxPriceRateDeviation,
            "miner supplied exchange rate is invalid");
    }

    function caculateVariance(
        uint[] arr,
        uint avg
        )
        internal
        constant
        returns (uint) {

        uint len = arr.length;
        uint variance = 0;
        for (uint i = 0; i < len; i++) {
            uint _sub = 0;
            if (arr[i] > avg) {
                _sub = arr[i] - avg;
            } else {
                _sub = avg - arr[i];
            }
            variance += _sub.mul(_sub);
        }
        variance = variance.div(len);
        variance = variance.div(avg).div(avg);
        return variance;
    }

    function calculateRingFees(
        uint ringSize,
        Ring ring
        )
        internal
        constant {

        uint minerLrcSpendable = getLRCSpendable(ring.feeRecepient);

        for (uint i = 0; i < ringSize; i++) {
            var state = ring.orders[i];
            var next = ring.orders[i.next(ringSize)];

            if (state.savingShareelection == FEE_SELECT_LRC) {

                uint lrcSpendable = getLRCSpendable(state.owner);

                if (lrcSpendable < state.lrcFee) {
                    if (ring.throwIfLRCIsInsuffcient) {
                        revert();
                    }

                    state.lrcFee = lrcSpendable;
                }

            } else if (state.savingShareelection == FEE_SELECT_SAVING_SHARE) {
                if (minerLrcSpendable >= state.lrcFee) {
                    uint savings;
                    if (state.order.buyNoMoreThanAmountB) {
                        savings = next.fillAmountS
                            .mul(state.order.amountS)
                            .div(state.order.amountB)
                            .sub(state.fillAmountS);

                    } else {
                        savings = next.fillAmountS.sub(
                            state.fillAmountS
                                .mul(state.order.amountB)
                                .div(state.order.amountS));
                    }

                    state.savingShare = savings
                        .mul(state.order.savingSharePercentage)
                        .div(SAVING_SHARE_PERCENTAGE_BASE);

                    // This implicits that has smaller index in the ring will
                    // be paid LRC reward first, so the orders in the ring does
                    // mater.
                    if (state.savingShare > 0) {
                        minerLrcSpendable = minerLrcSpendable.sub(state.lrcFee);
                        state.lrcReward = state.lrcFee;
                    }
                    // Do not charge LRC fee if miner doest' have enough to pay
                    // LRC reward.
                    state.lrcFee = 0;
                }
            } else revert();

        }

    }

    function calculateRingFillAmount(
        uint ringSize,
        Ring ring
        )
        internal
        constant {

        uint smallestIdx = 0;
        uint i;
        uint j;

        for (i = 0; i < ringSize; i++) {
            j = i.next(ring.orders.length);

            uint res = calculateOrderFillAmount(
                ring.orders[i],
                ring.orders[j]);

            if (res == 1) smallestIdx = i;
            else if (res == 2) smallestIdx = j;
        }

        for (i = 0; i < smallestIdx; i++) {
            j = i.next(ring.orders.length);
            check(
                0 == calculateOrderFillAmount(ring.orders[i], ring.orders[j]),
                "unexpected exception in calculateRingFillAmount");
        }
    }

    /// @return 0 if neither order is the smallest one;
    ///         1 if 'state' is the smallest order;
    ///         2 if 'next' is the smallest order.
    function calculateOrderFillAmount(
        OrderState state,
        OrderState next
        )
        internal
        constant
        returns (uint state2IsSmaller) {

        // Update the amount of tokenB this order can buy, whose logic could be
        // a brain-burner:
        // We have `fillAmountB / state.fillAmountS = state.rateAmountB / state.rateAmountS`,
        // therefore, `fillAmountB = state.rateAmountB * state.fillAmountS / state.rateAmountS`,
        // therefore  `fillAmountB = next.rateAmountS * state.fillAmountS / state.rateAmountS`,
        uint fillAmountB  = next.rateAmountS
            .mul(state.fillAmountS)
            .div(state.rateAmountS);

        if (state.order.buyNoMoreThanAmountB) {
            if (fillAmountB > state.order.amountB) {
                fillAmountB = state.order.amountB;

                state.fillAmountS = state.rateAmountS
                    .mul(fillAmountB)
                    .div(next.rateAmountS);

                state2IsSmaller = 1;
            }

            state.lrcFee = state.order.lrcFee
                .mul(fillAmountB)
                .div(next.order.amountS);
        } else {
            state.lrcFee = state.order.lrcFee
                .mul(state.fillAmountS)
                .div(state.order.amountS);
        }

        if (fillAmountB <= next.fillAmountS) {
            next.fillAmountS = fillAmountB;
        } else {
            state2IsSmaller = 2;
        }
    }


    /// @dev Scale down all orders based on historical fill or cancellation
    ///      stats but key the order's original exchange rate.
    function scaleRingBasedOnHistoricalRecords(
        uint ringSize,
        Ring ring
        )
        internal
        constant {

        for (uint i = 0; i < ringSize; i++) {
            var state = ring.orders[i];
            var order = state.order;

            if (order.buyNoMoreThanAmountB) {
                uint amountB = order.amountB
                    .sub(filled[state.orderHash])
                    .tolerantSub(cancelled[state.orderHash]);

                order.amountS = amountB.mul(order.amountS).div(order.amountB);
                order.lrcFee = amountB.mul(order.lrcFee).div(order.amountB);

                order.amountB = amountB;
            } else {
                uint amountS = order.amountS
                    .sub(filled[state.orderHash])
                    .tolerantSub(cancelled[state.orderHash]);

                order.amountB = amountS.mul(order.amountB).div(order.amountS);
                order.lrcFee = amountS.mul(order.lrcFee).div(order.amountS);

                order.amountS = amountS;
            }

            check(order.amountS > 0, "amountS is zero");
            check(order.amountB > 0, "amountB is zero");

            state.fillAmountS = order.amountS.min256(state.availableAmountS);
        }
    }

    /// @return Amount of ERC20 token that can be spent by this contract.
    function getSpendable(
        address tokenAddress,
        address tokenOwner
        )
        internal
        constant
        returns (uint) {

        var token = ERC20(tokenAddress);
        return token
            .allowance(tokenOwner, address(this))
            .min256(token.balanceOf(tokenOwner));
    }

    /// @return Amount of LRC token that can be spent by this contract.
    function getLRCSpendable(address tokenOwner)
        internal
        constant
        returns (uint) {

        return getSpendable(lrcTokenAddress, tokenOwner);
    }

    function verifyInputDataIntegrity(
        uint ringSize,
        address[]   tokenSList,
        uint[6][]   uintArgsList,
        uint8[2][]  uint8ArgsList,
        bool[]      buyNoMoreThanAmountBList,
        uint8[]     vList,
        bytes32[]   rList,
        bytes32[]   sList
        )
        internal
        constant {

        check(ringSize == tokenSList.length,
            "ring data is inconsistent - tokenSList");
        check(ringSize == uintArgsList.length,
            "ring data is inconsistent - uintArgsList");
        check(ringSize == uint8ArgsList.length,
            "ring data is inconsistent - uint8ArgsList");
        check(ringSize == buyNoMoreThanAmountBList.length,
            "ring data is inconsistent - buyNoMoreThanAmountBList");
        check(ringSize + 1 == vList.length,
            "ring data is inconsistent - vList");
        check(ringSize + 1 == rList.length,
            "ring data is inconsistent - rList");
        check(ringSize + 1 == sList.length,
            "ring data is inconsistent - sList");
    }

    /// @dev        assmble order parameters into Order struct.
    /// @return     A list of orders.
    function assembleOrders(
        uint        ringSize,
        address[]   tokenSList,
        uint[6][]   uintArgsList,
        uint8[2][]  uint8ArgsList,
        bool[]      buyNoMoreThanAmountBList,
        uint8[]     vList,
        bytes32[]   rList,
        bytes32[]   sList
        )
        internal
        constant
        returns (OrderState[]) {

        var orders = new OrderState[](ringSize);

        for (uint i = 0; i < ringSize; i++) {
            uint j = i.prev(ringSize);

            var order = Order(
                tokenSList[i],
                tokenSList[j],
                uintArgsList[i][0],
                uintArgsList[i][1],
                uintArgsList[i][2],
                uintArgsList[i][3],
                uintArgsList[i][4],
                buyNoMoreThanAmountBList[i],
                uint8ArgsList[i][0],
                vList[i],
                rList[i],
                sList[i]);

            validateOrder(order);

            bytes32 orderHash = calculateOrderHash(order);

            address orderOwner = calculateSignerAddress(
                orderHash,
                order.v,
                order.r,
                order.s);

            orders[i] = OrderState(
                order,
                orderHash,
                orderOwner,
                uint8ArgsList[i][1],  // savingShareelectionList
                uintArgsList[i][5],   // rateAmountS
                getSpendable(order.tokenS, orderOwner),
                0,   // fillAmountS
                0,   // lrcReward
                0,   // lrcFee
                0    // savingShare
                );

            check(orders[i].availableAmountS > 0, "order balance is zero");
        }

        return orders;
    }

    /// @dev validate order's parameters are OK.
    function validateOrder(Order order) internal constant {
        check(order.tokenS != address(0),
            "invalid order tokenS");
        check(order.tokenB != address(0),
            "invalid order tokenB");
        check(order.amountS > 0,
            "invalid order amountS");
        check(order.amountB > 0,
            "invalid order amountB");
        check(order.expiration > block.number,
            "invalid order expiration");
        check(order.rand > 0,
            "invalid order rand");
        check(order.savingSharePercentage <= SAVING_SHARE_PERCENTAGE_BASE,
            "invalid order savingSharePercentage");
    }

    /// @dev Get the Keccak-256 hash of order with specified parameters.
    function calculateOrderHash(Order order)
        internal
        constant
        returns (bytes32) {

        return keccak256(
            address(this),
            order.tokenS,
            order.tokenB,
            order.amountS,
            order.amountB,
            order.expiration,
            order.rand,
            order.lrcFee,
            order.buyNoMoreThanAmountB,
            order.savingSharePercentage);
    }

    /// @return The signer's address.
    function calculateSignerAddress(
        bytes32 hash,
        uint8 v,
        bytes32 r,
        bytes32 s)
        public
        constant
        returns (address) {

        return ecrecover(
            keccak256("\x19Ethereum Signed Message:\n32", hash),
            v,
            r,
            s);
    }

    function check(
        bool condition,
        string message) {
        if (!condition) {
            Exception(message);
            revert();
        }
    }
}
