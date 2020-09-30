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

contract DSPause is DSAuth, DSNote {
    // --- Admin ---
    modifier isDelayed { require(msg.sender == address(proxy), "ds-pause-undelayed-call"); _; }

    function setOwner(address owner_) override public isDelayed {
        owner = owner_;
        emit LogSetOwner(owner);
    }
    function setAuthority(DSAuthority authority_) override public isDelayed {
        authority = authority_;
        emit LogSetAuthority(address(authority));
    }
    function setDelay(uint delay_) public isDelayed {
        require(delay_ <= MAX_DELAY, "ds-pause-delay-not-within-bounds");
        delay = delay_;
        emit SetDelay(delay_);
    }

    // --- Math ---
    function addition(uint x, uint y) internal pure returns (uint z) {
        z = x + y;
        require(z >= x, "ds-pause-add-overflow");
    }
    function subtract(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x, "ds-pause-sub-underflow");
    }

    // --- Structs ---
    struct TransactionDetails {
        address usr;
        uint256 earliestExecutionTime;
        bytes32 codeHash;
        bytes parameters;
    }

    // --- Data ---
    mapping (bytes32 => bool)               public scheduledTransactions;
    mapping (uint256 => TransactionDetails) public transactionDetails;
    mapping (bytes32 => uint256)            public txHashId;

    DSPauseProxy               public proxy;

    uint                       public nonce;
    uint                       public delay;
    uint                       public currentlyScheduledTransactions;

    uint256                    public constant EXEC_TIME                = 3 days;
    uint256                    public constant maxScheduledTransactions = 10;
    uint256                    public constant MAX_DELAY                = 28 days;
    bytes32                    public constant DS_PAUSE_TYPE            = bytes32("BASIC");

    // --- Events ---
    event SetDelay(uint256 delay);
    event ScheduleTransaction(address sender, uint txId, address usr, bytes32 codeHash, bytes parameters, uint earliestExecutionTime);
    event AbandonTransaction(address sender, uint txId, address usr, bytes32 codeHash, bytes parameters, uint earliestExecutionTime);
    event ExecuteTransaction(address sender, uint txId, address usr, bytes32 codeHash, bytes parameters, uint earliestExecutionTime);
    event AttachTransactionDescription(address sender, uint txId, address usr, bytes32 codeHash, bytes parameters, uint earliestExecutionTime, string description);

    // --- Init ---
    constructor(uint delay_, address owner_, DSAuthority authority_) public {
        require(delay_ <= MAX_DELAY, "ds-pause-delay-not-within-bounds");
        delay = delay_;
        owner = owner_;
        authority = authority_;
        proxy = new DSPauseProxy();
    }

    // --- Util ---
    function getTransactionDataHash(address usr, bytes32 codeHash, bytes memory parameters, uint earliestExecutionTime)
        public pure
        returns (bytes32)
    {
        return keccak256(abi.encode(usr, codeHash, parameters, earliestExecutionTime));
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
        schedule(usr, codeHash, parameters, earliestExecutionTime);
    }
    function scheduleTransaction(address usr, bytes32 codeHash, bytes memory parameters, uint earliestExecutionTime, string memory description)
        public auth
    {
        schedule(usr, codeHash, parameters, earliestExecutionTime);
        emit AttachTransactionDescription(msg.sender, nonce, usr, codeHash, parameters, earliestExecutionTime, description);
    }
    function attachTransactionDescription(address usr, bytes32 codeHash, bytes memory parameters, uint earliestExecutionTime, string memory description)
        public auth
    {
        bytes32 hashedTx = getTransactionDataHash(usr, codeHash, parameters, earliestExecutionTime);
        require(scheduledTransactions[hashedTx], "ds-pause-unscheduled-tx");

        emit AttachTransactionDescription(msg.sender, txHashId[hashedTx], usr, codeHash, parameters, earliestExecutionTime, description);
    }
    function attachTransactionDescription(uint256 txId, string memory description)
        public auth
    {
        require(txId <= nonce, "ds-pause-inexistent-tx");

        address usr                = transactionDetails[txId].usr;
        bytes32 codeHash           = transactionDetails[txId].codeHash;
        bytes memory parameters    = transactionDetails[txId].parameters;
        uint earliestExecutionTime = transactionDetails[txId].earliestExecutionTime;

        bytes32 hashedTx = getTransactionDataHash(usr, codeHash, parameters, earliestExecutionTime);
        require(scheduledTransactions[hashedTx], "ds-pause-unscheduled-tx");

        emit AttachTransactionDescription(msg.sender, txId, usr, codeHash, parameters, earliestExecutionTime, description);
    }
    function abandonTransaction(address usr, bytes32 codeHash, bytes memory parameters, uint earliestExecutionTime)
        public auth
    {
        bytes32 hashedTx = getTransactionDataHash(usr, codeHash, parameters, earliestExecutionTime);
        require(scheduledTransactions[hashedTx], "ds-pause-unscheduled-tx");

        scheduledTransactions[hashedTx] = false;
        currentlyScheduledTransactions  = subtract(currentlyScheduledTransactions, 1);

        emit AbandonTransaction(msg.sender, txHashId[hashedTx], usr, codeHash, parameters, earliestExecutionTime);

        delete(transactionDetails[txHashId[hashedTx]]);
        txHashId[hashedTx]              = 0;
    }
    function abandonTransaction(uint256 txId)
        public auth
    {
        require(txId <= nonce, "ds-pause-inexistent-tx");

        address usr                = transactionDetails[txId].usr;
        bytes32 codeHash           = transactionDetails[txId].codeHash;
        bytes memory parameters    = transactionDetails[txId].parameters;
        uint earliestExecutionTime = transactionDetails[txId].earliestExecutionTime;

        bytes32 hashedTx = getTransactionDataHash(usr, codeHash, parameters, earliestExecutionTime);
        require(scheduledTransactions[hashedTx], "ds-pause-unscheduled-tx");

        scheduledTransactions[hashedTx] = false;
        currentlyScheduledTransactions  = subtract(currentlyScheduledTransactions, 1);

        emit AbandonTransaction(msg.sender, txId, usr, codeHash, parameters, earliestExecutionTime);

        delete(transactionDetails[txHashId[hashedTx]]);
        txHashId[hashedTx]              = 0;
    }
    function executeTransaction(address usr, bytes32 codeHash, bytes memory parameters, uint earliestExecutionTime)
        public
        returns (bytes memory out)
    {
        require(getExtCodeHash(usr) == codeHash, "ds-pause-wrong-codehash");

        bytes32 hashedTx = getTransactionDataHash(usr, codeHash, parameters, earliestExecutionTime);
        require(scheduledTransactions[hashedTx], "ds-pause-unscheduled-tx");

        emit ExecuteTransaction(msg.sender, txHashId[hashedTx], usr, codeHash, parameters, earliestExecutionTime);
        checkExecutionAndRemoveScheduled(hashedTx, earliestExecutionTime);

        out = proxy.executeTransaction(usr, parameters);
        require(proxy.owner() == address(this), "ds-pause-illegal-storage-change");
    }
    function executeTransaction(uint txId)
        public
        returns (bytes memory out)
    {
        require(txId <= nonce, "ds-pause-inexistent-tx");

        address usr                = transactionDetails[txId].usr;
        bytes32 codeHash           = transactionDetails[txId].codeHash;
        bytes memory parameters    = transactionDetails[txId].parameters;
        uint earliestExecutionTime = transactionDetails[txId].earliestExecutionTime;

        require(getExtCodeHash(usr) == codeHash, "ds-pause-wrong-codehash");

        bytes32 hashedTx = getTransactionDataHash(usr, codeHash, parameters, earliestExecutionTime);
        require(scheduledTransactions[hashedTx], "ds-pause-unscheduled-tx");

        emit ExecuteTransaction(msg.sender, txId, usr, codeHash, parameters, earliestExecutionTime);
        checkExecutionAndRemoveScheduled(hashedTx, earliestExecutionTime);

        out = proxy.executeTransaction(usr, parameters);
        require(proxy.owner() == address(this), "ds-pause-illegal-storage-change");
    }

    // --- Internal ---
    function schedule(address usr, bytes32 codeHash, bytes memory parameters, uint earliestExecutionTime) internal {
        bytes32 hashedTx = getTransactionDataHash(usr, codeHash, parameters, earliestExecutionTime);

        require(!scheduledTransactions[hashedTx], "ds-pause-plotted-plan");
        require(subtract(earliestExecutionTime, now) <= MAX_DELAY, "ds-pause-delay-not-within-bounds");
        require(earliestExecutionTime >= addition(now, delay), "ds-pause-delay-not-respected");
        require(currentlyScheduledTransactions < maxScheduledTransactions, "ds-pause-too-many-scheduled");
        require(txHashId[hashedTx] == 0, "ds-pause-tx-already-scheduled");

        currentlyScheduledTransactions  = addition(currentlyScheduledTransactions, 1);
        nonce                           = addition(nonce, 1);
        scheduledTransactions[hashedTx] = true;
        txHashId[hashedTx]              = nonce;
        transactionDetails[nonce]       = TransactionDetails(usr, earliestExecutionTime, codeHash, parameters);

        emit ScheduleTransaction(msg.sender, nonce, usr, codeHash, parameters, earliestExecutionTime);
    }
    function checkExecutionAndRemoveScheduled(bytes32 hashedTx, uint earliestExecutionTime) internal {
        require(now >= earliestExecutionTime, "ds-pause-premature-exec");
        require(now <= addition(earliestExecutionTime, EXEC_TIME), "ds-pause-expired-tx");

        scheduledTransactions[hashedTx] = false;
        currentlyScheduledTransactions  = subtract(currentlyScheduledTransactions, 1);

        delete(transactionDetails[txHashId[hashedTx]]);
        txHashId[hashedTx]              = 0;
    }
}

// scheduled txs are executed in an isolated storage context to protect the pause from
// malicious storage modification during plan execution
contract DSPauseProxy {
    address public owner;
    modifier isAuthorized { require(msg.sender == owner, "ds-pause-proxy-unauthorized"); _; }
    constructor() public { owner = msg.sender; }

    function executeTransaction(address usr, bytes memory parameters)
        public isAuthorized
        returns (bytes memory out)
    {
        bool ok;
        (ok, out) = usr.delegatecall(parameters);
        require(ok, "ds-pause-delegatecall-error");
    }
}
