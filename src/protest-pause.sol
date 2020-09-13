// Copyright (C) 2019 David Terry <me@xwvvvvwx.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity >=0.6.7;

import {DSNote} from "ds-note/note.sol";
import {DSAuth, DSAuthority} from "ds-auth/auth.sol";

contract DSProtestPause is DSAuth, DSNote {
    // --- Admin ---
    modifier isDelayed { require(msg.sender == address(proxy), "ds-protest-pause-undelayed-call"); _; }

    function setOwner(address owner_) override public isDelayed {
        owner = owner_;
        emit LogSetOwner(owner);
    }
    function setAuthority(DSAuthority authority_) override public isDelayed {
        authority = authority_;
        emit LogSetAuthority(address(authority));
    }
    function setDelay(uint delay_) public isDelayed {
        delay = delay_;
        emit SetDelay(delay_);
    }
    function setDelayMultiplier(uint multiplier_) public isDelayed {
        require(both(multiplier_ >= 1, multiplier_ <= MAX_MULTIPLIER), "ds-protest-pause-multiplier-exceeds-bounds");
        delayMultiplier = multiplier_;
        emit ChangeDelayMultiplier(multiplier_);
    }

    // --- Structs ---
    struct TransactionDelay {
        bool protested;
        uint scheduleTime;
        uint totalDelay;
    }

    // --- Data ---
    mapping (bytes32 => bool)             public scheduledTransactions;
    mapping (bytes32 => TransactionDelay) internal transactionDelays;

    DSPauseProxy  public proxy;
    address       public protester;

    uint          public delay;
    uint          public delayMultiplier = 1;
    uint constant public MAX_MULTIPLIER  = 3;

    bytes32       public constant DS_PAUSE_TYPE = bytes32("PROTEST");

    // --- Events ---
    event SetDelay(uint256 delay);
    event ChangeDelayMultiplier(uint256 multiplier);
    event ScheduleTransaction(address sender, address usr, bytes32 codeHash, bytes parameters, uint earliestExecutionTime);
    event AbandonTransaction(address sender, address usr, bytes32 codeHash, bytes parameters, uint earliestExecutionTime);
    event ProtestAgainstTransaction(address sender, address usr, bytes32 codeHash, bytes parameters, uint totalDelay);
    event ExecuteTransaction(address sender, address usr, bytes32 codeHash, bytes parameters, uint earliestExecutionTime);
    event AttachTransactionDescription(address sender, address usr, bytes32 codeHash, bytes parameters, uint earliestExecutionTime, string description);

    // --- Init ---
    constructor(uint delay_, address owner_, DSAuthority authority_) public {
        delay = delay_;
        owner = owner_;
        authority = authority_;
        proxy = new DSPauseProxy();
    }

    // --- Math ---
    function addition(uint x, uint y) internal pure returns (uint z) {
        z = x + y;
        require(z >= x, "ds-protest-pause-add-overflow");
    }
    function subtract(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x, "ds-protest-pause-sub-underflow");
    }
    function multiply(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x, "ds-protest-pause-mul-invalid");
    }

    // --- Boolean Logic ---
    function both(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := and(x, y)}
    }

    // --- Util ---
    function getTransactionDataHash(address usr, bytes32 codeHash, bytes memory parameters, uint earliestExecutionTime)
        internal pure
        returns (bytes32)
    {
        return keccak256(abi.encode(usr, codeHash, parameters, earliestExecutionTime));
    }
    function getTransactionDataHash(address usr, bytes32 codeHash, bytes memory parameters)
        internal pure
        returns (bytes32)
    {
        return keccak256(abi.encode(usr, codeHash, parameters));
    }

    function getExtCodeHash(address usr)
        internal view
        returns (bytes32 codeHash)
    {
        assembly { codeHash := extcodehash(usr) }
    }

    // --- Operations ---
    function scheduleTransaction(address usr, bytes32 codeHash, bytes memory parameters, uint earliestExecutionTime)
        public auth
    {
        require(earliestExecutionTime >= addition(now, delay), "ds-protest-pause-delay-not-respected");
        require(transactionDelays[getTransactionDataHash(usr, codeHash, parameters)].scheduleTime == 0, "ds-protest-pause-cannot-schedule-same-tx-twice");
        scheduledTransactions[getTransactionDataHash(usr, codeHash, parameters, earliestExecutionTime)] = true;
        transactionDelays[getTransactionDataHash(usr, codeHash, parameters)] = TransactionDelay(false, now, subtract(earliestExecutionTime, now));
        emit ScheduleTransaction(msg.sender, usr, codeHash, parameters, earliestExecutionTime);
    }
    function scheduleTransaction(address usr, bytes32 codeHash, bytes memory parameters, uint earliestExecutionTime, string memory description)
        public auth
    {
        require(earliestExecutionTime >= addition(now, delay), "ds-protest-pause-delay-not-respected");
        require(transactionDelays[getTransactionDataHash(usr, codeHash, parameters)].scheduleTime == 0, "ds-protest-pause-cannot-schedule-same-tx-twice");
        scheduledTransactions[getTransactionDataHash(usr, codeHash, parameters, earliestExecutionTime)] = true;
        transactionDelays[getTransactionDataHash(usr, codeHash, parameters)] = TransactionDelay(false, now, subtract(earliestExecutionTime, now));
        emit ScheduleTransaction(msg.sender, usr, codeHash, parameters, earliestExecutionTime);
        emit AttachTransactionDescription(msg.sender, usr, codeHash, parameters, earliestExecutionTime, description);
    }
    function attachTransactionDescription(address usr, bytes32 codeHash, bytes memory parameters, uint earliestExecutionTime, string memory description)
        public auth
    {
        emit AttachTransactionDescription(msg.sender, usr, codeHash, parameters, earliestExecutionTime, description);
    }
    function protestAgainstTransaction(address usr, bytes32 codeHash, bytes memory parameters, uint earliestExecutionTime)
        public
    {
        require(msg.sender == protester, "ds-protest-pause-sender-not-protester");
        bytes32 partiallyHashedTx = getTransactionDataHash(usr, codeHash, parameters);
        require(transactionDelays[partiallyHashedTx].scheduleTime > 0, "ds-protest-pause-null-inexistent-transaction");
        require(!transactionDelays[partiallyHashedTx].protested, "ds-protest-pause-tx-already-protested");

        transactionDelays[partiallyHashedTx].protested = true;

        uint multipliedDelay = multiply(delay, delayMultiplier);
        if (transactionDelays[partiallyHashedTx].totalDelay < multipliedDelay) {
          transactionDelays[partiallyHashedTx].totalDelay = multipliedDelay;
        }

        emit ProtestAgainstTransaction(msg.sender, usr, codeHash, parameters, transactionDelays[partiallyHashedTx].totalDelay);
    }
    function abandonTransaction(address usr, bytes32 codeHash, bytes memory parameters, uint earliestExecutionTime)
        public auth
    {
        scheduledTransactions[getTransactionDataHash(usr, codeHash, parameters, earliestExecutionTime)] = false;
        delete(transactionDelays[getTransactionDataHash(usr, codeHash, parameters)]);
        emit AbandonTransaction(msg.sender, usr, codeHash, parameters, earliestExecutionTime);
    }
    function executeTransaction(address usr, bytes32 codeHash, bytes memory parameters, uint earliestExecutionTime)
        public
        returns (bytes memory out)
    {
        require(scheduledTransactions[getTransactionDataHash(usr, codeHash, parameters, earliestExecutionTime)], "ds-protest-pause-inexistent-transaction");
        require(getExtCodeHash(usr) == codeHash, "ds-protest-pause-wrong-codehash");

        bytes32 partiallyHashedTx = getTransactionDataHash(usr, codeHash, parameters);
        require(now >= addition(transactionDelays[partiallyHashedTx].scheduleTime, transactionDelays[partiallyHashedTx].totalDelay), "ds-protest-pause-premature-exec");

        scheduledTransactions[getTransactionDataHash(usr, codeHash, parameters, earliestExecutionTime)] = false;
        delete(transactionDelays[partiallyHashedTx]);

        emit ExecuteTransaction(msg.sender, usr, codeHash, parameters, earliestExecutionTime);

        out = proxy.executeTransaction(usr, parameters);
        require(proxy.owner() == address(this), "ds-protest-pause-illegal-storage-change");
    }

    // --- Getters ---
    function getTransactionDelays(address usr, bytes32 codeHash, bytes calldata parameters) external view returns (bool, uint256, uint256) {
        bytes32 partiallyHashedTx = getTransactionDataHash(usr, codeHash, parameters);
        return (
          transactionDelays[partiallyHashedTx].protested,
          transactionDelays[partiallyHashedTx].scheduleTime,
          transactionDelays[partiallyHashedTx].totalDelay
        );
    }
    function getTransactionDelays(bytes32 txHash) external view returns (bool, uint256, uint256) {
        return (
          transactionDelays[txHash].protested,
          transactionDelays[txHash].scheduleTime,
          transactionDelays[txHash].totalDelay
        );
    }
}

// scheduled txs are executed in an isolated storage context to protect the pause from
// malicious storage modification during plan execution
contract DSPauseProxy {
    address public owner;
    modifier isAuthorized { require(msg.sender == owner, "ds-protest-pause-proxy-unauthorized"); _; }
    constructor() public { owner = msg.sender; }

    function executeTransaction(address usr, bytes memory parameters)
        public isAuthorized
        returns (bytes memory out)
    {
        bool ok;
        (ok, out) = usr.delegatecall(parameters);
        require(ok, "ds-protest-pause-delegatecall-error");
    }
}
