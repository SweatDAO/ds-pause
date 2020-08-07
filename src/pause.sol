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

    // --- admin ---

    modifier isDelayed { require(msg.sender == address(proxy), "ds-pause-undelayed-call"); _; }

    function setOwner(address owner_) override public note isDelayed {
        owner = owner_;
        emit LogSetOwner(owner);
    }
    function setAuthority(DSAuthority authority_) override public note isDelayed {
        authority = authority_;
        emit LogSetAuthority(address(authority));
    }
    function setDelay(uint delay_) public note isDelayed {
        delay = delay_;
    }

    // --- math ---

    function addition(uint x, uint y) internal pure returns (uint z) {
        z = x + y;
        require(z >= x, "ds-pause-add-overflow");
    }

    // --- data ---

    mapping (bytes32 => bool) public scheduledTransactions;
    DSPauseProxy public proxy;
    uint         public delay;

    // --- events ---

    event ScheduleTransaction(address sender, address usr, bytes32 codeHash, bytes parameters, uint earliestExecutionTime);
    event AbandonTransaction(address sender, address usr, bytes32 codeHash, bytes parameters, uint earliestExecutionTime);
    event ExecuteTransaction(address sender, address usr, bytes32 codeHash, bytes parameters, uint earliestExecutionTime);

    // --- init ---

    constructor(uint delay_, address owner_, DSAuthority authority_) public {
        delay = delay_;
        owner = owner_;
        authority = authority_;
        proxy = new DSPauseProxy();
    }

    // --- util ---

    function getTransactionDataHash(address usr, bytes32 codeHash, bytes memory parameters, uint earliestExecutionTime)
        internal pure
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

    // --- operations ---

    function scheduleTransaction(address usr, bytes32 codeHash, bytes memory parameters, uint earliestExecutionTime)
        public note auth
    {
        require(earliestExecutionTime >= addition(now, delay), "ds-pause-delay-not-respected");
        scheduledTransactions[getTransactionDataHash(usr, codeHash, parameters, earliestExecutionTime)] = true;
        emit ScheduleTransaction(msg.sender, usr, codeHash, parameters, earliestExecutionTime);
    }

    function abandonTransaction(address usr, bytes32 codeHash, bytes memory parameters, uint earliestExecutionTime)
        public note auth
    {
        scheduledTransactions[getTransactionDataHash(usr, codeHash, parameters, earliestExecutionTime)] = false;
        emit AbandonTransaction(msg.sender, usr, codeHash, parameters, earliestExecutionTime);
    }

    function executeTransaction(address usr, bytes32 codeHash, bytes memory parameters, uint earliestExecutionTime)
        public note
        returns (bytes memory out)
    {
        require(scheduledTransactions[getTransactionDataHash(usr, codeHash, parameters, earliestExecutionTime)], "ds-pause-unplotted-plan");
        require(getExtCodeHash(usr) == codeHash, "ds-pause-wrong-codehash");
        require(now >= earliestExecutionTime, "ds-pause-premature-exec");

        scheduledTransactions[getTransactionDataHash(usr, codeHash, parameters, earliestExecutionTime)] = false;

        emit ExecuteTransaction(msg.sender, usr, codeHash, parameters, earliestExecutionTime);

        out = proxy.executeTransaction(usr, parameters);
        require(proxy.owner() == address(this), "ds-pause-illegal-storage-change");
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
