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

pragma solidity 0.6.7;

import {DSTest} from "ds-test/test.sol";
import {DSAuth, DSAuthority} from "ds-auth/auth.sol";

import {DSPause} from "../pause.sol";

// ------------------------------------------------------------------
// Test Harness
// ------------------------------------------------------------------

abstract contract Hevm {
    function warp(uint) virtual public;
}

contract Target {
    address owner;
    function give(address usr) public {
        owner = usr;
    }

    function get() public pure returns (bytes32) {
        return bytes32("Hello");
    }
}

contract Stranger {
    function scheduleTransaction(DSPause pause, address usr, bytes32 codeHash, bytes memory parameters, uint eta) public {
        pause.scheduleTransaction(usr, codeHash, parameters, eta);
    }
    function abandonTransaction(DSPause pause, address usr, bytes32 codeHash, bytes memory parameters, uint eta) public {
        pause.abandonTransaction(usr, codeHash, parameters, eta);
    }
    function executeTransaction(DSPause pause, address usr, bytes32 codeHash, bytes memory parameters, uint eta)
        public returns (bytes memory)
    {
        return pause.executeTransaction(usr, codeHash, parameters, eta);
    }
}

contract Authority is DSAuthority {
    address owner;

    constructor() public {
        owner = msg.sender;
    }

    function canCall(address src, address, bytes4)
        override
        public
        view
        returns (bool)
    {
        require(src == owner);
        return true;
    }
}

// ------------------------------------------------------------------
// Common Setup & Test Utils
// ------------------------------------------------------------------

contract Test is DSTest {
    Hevm hevm;
    DSPause pause;
    Stranger stranger;
    address target;

    function setUp() public {
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(604411200);

        target = address(new Target());
        stranger = new Stranger();

        uint delay = 1 days;
        pause = new DSPause(delay, address(0x0), new Authority());


    }

    // returns the 1st 32 bytes of data from a bytes array
    function b32(bytes memory data) public pure returns (bytes32 data32) {
        assembly {
            data32 := mload(add(data, 32))
        }
    }

    function extcodehash(address usr) internal view returns (bytes32 ch) {
        assembly { ch := extcodehash(usr) }
    }
}

// ------------------------------------------------------------------
// Proxy Scripts
// ------------------------------------------------------------------

contract AdminScripts {
    function setDelay(DSPause pause, uint delay) public {
        pause.setDelay(delay);
    }
    function setOwner(DSPause pause, address owner) public {
        pause.setOwner(owner);
    }
    function setAuthority(DSPause pause, DSAuthority authority) public {
        pause.setAuthority(authority);
    }
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

contract Constructor is DSTest {
    function setUp() public {}
    function test_delay_set() public {
        DSPause pause = new DSPause(100, address(0x0), new Authority());
        assertEq(pause.delay(), 100);
    }

    function test_owner_set() public {
        DSPause pause = new DSPause(100, address(0xdeadbeef), new Authority());
        assertEq(address(pause.owner()), address(0xdeadbeef));
    }

    function test_authority_set() public {
        Authority authority = new Authority();
        DSPause pause = new DSPause(100, address(0x0), authority);
        assertEq(address(pause.authority()), address(authority));
    }
}

contract Admin is Test {

    // --- owner ---

    function testFail_cannot_set_owner_without_delay() public {
        pause.setOwner(address(this));
    }

    function test_set_owner_with_delay() public {
        address      usr = address(new AdminScripts());
        bytes32      codeHash = extcodehash(usr);
        bytes memory parameters = abi.encodeWithSignature("setOwner(address,address)", pause, 0xdeadbeef);
        uint         eta = now + pause.delay();

        pause.scheduleTransaction(usr, codeHash, parameters, eta);
        hevm.warp(eta);
        pause.executeTransaction(usr, codeHash, parameters, eta);

        assertEq(address(pause.owner()), address(0xdeadbeef));
    }

    // --- authority ---

    function testFail_cannot_set_authority_without_delay() public {
        pause.setAuthority(new Authority());
    }

    function test_set_authority_with_delay() public {
        DSAuthority newAuthority = new Authority();

        address      usr = address(new AdminScripts());
        bytes32      codeHash = extcodehash(usr);
        bytes memory parameters = abi.encodeWithSignature("setAuthority(address,address)", pause, newAuthority);
        uint         eta = now + pause.delay();

        pause.scheduleTransaction(usr, codeHash, parameters, eta);
        hevm.warp(eta);
        pause.executeTransaction(usr, codeHash, parameters, eta);

        assertEq(address(pause.authority()), address(newAuthority));
    }

    // --- delay ---

    function testFail_cannot_set_delay_without_delay() public {
        pause.setDelay(0);
    }

    function test_set_delay_with_delay() public {
        address      usr = address(new AdminScripts());
        bytes32      codeHash = extcodehash(usr);
        bytes memory parameters = abi.encodeWithSignature("setDelay(address,uint256)", pause, 0);
        uint         eta = now + pause.delay();

        pause.scheduleTransaction(usr, codeHash, parameters, eta);
        hevm.warp(eta);
        pause.executeTransaction(usr, codeHash, parameters, eta);

        assertEq(pause.delay(), 0);
    }
}

contract Schedule is Test {

    function testFail_call_from_unauthorized() public {
        address      usr = target;
        bytes32      codeHash = extcodehash(usr);
        bytes memory parameters = abi.encodeWithSignature("get()");
        uint         eta = now + pause.delay();

        stranger.scheduleTransaction(pause, usr, codeHash, parameters, eta);
    }

    function testFail_schedule_eta_too_soon() public {
        address      usr = target;
        bytes32      codeHash = extcodehash(usr);
        bytes memory parameters = abi.encodeWithSignature("get()");
        uint         eta = now;

        pause.scheduleTransaction(usr, codeHash, parameters, eta);
    }

    function testFail_schedule_above_max_scheduled_txs() public {
        address      usr = target;
        bytes32      codeHash = extcodehash(usr);
        uint         eta = now + pause.delay();

        for (uint i = 0; i <= pause.maxScheduledTransactions(); i++) {
            bytes memory parameters = abi.encodeWithSignature("give(uint256)", address(i));
            pause.scheduleTransaction(usr, codeHash, parameters, eta);
        }
    }

    function testFail_schedule_eta_above_max_delay() public {
        address      usr = target;
        bytes32      codeHash = extcodehash(usr);
        bytes memory parameters = abi.encodeWithSignature("get()");
        uint         eta = now + pause.MAX_DELAY() + 1;

        pause.scheduleTransaction(usr, codeHash, parameters, eta);
    }

    function test_schedule_populates_scheduled_transactions_mapping() public {
        address      usr = target;
        bytes32      codeHash = extcodehash(usr);
        bytes memory parameters = abi.encodeWithSignature("get()");
        uint         eta = now + pause.delay();

        pause.scheduleTransaction(usr, codeHash, parameters, eta);

        bytes32 id = keccak256(abi.encode(usr, codeHash, parameters, eta));
        assertTrue(pause.scheduledTransactions(id));
    }

        function testFail_schedule_duplicate_transaction() public {
        address      usr = target;
        bytes32      codeHash = extcodehash(usr);
        bytes memory parameters = abi.encodeWithSignature("get()");
        uint         eta = now + pause.delay();

        pause.scheduleTransaction(usr, codeHash, parameters, eta);
        pause.scheduleTransaction(usr, codeHash, parameters, eta + 1);
    }

    function test_schedule_duplicate_transaction_after_execution() public {
        address      usr = target;
        bytes32      codeHash = extcodehash(usr);
        bytes memory parameters = abi.encodeWithSignature("get()");
        uint         eta = now + pause.delay();

        pause.scheduleTransaction(usr, codeHash, parameters, eta);
        hevm.warp(eta);
        pause.executeTransaction(usr, codeHash, parameters, eta);

        pause.scheduleTransaction(usr, codeHash, parameters, now + pause.delay());
        bytes32 id = keccak256(abi.encode(usr, codeHash, parameters, now + pause.delay()));
        assertTrue(pause.scheduledTransactions(id));
    }

    function test_schedule_duplicate_transaction_after_abandon() public {
        address      usr = target;
        bytes32      codeHash = extcodehash(usr);
        bytes memory parameters = abi.encodeWithSignature("get()");
        uint         eta = now + pause.delay();

        pause.scheduleTransaction(usr, codeHash, parameters, eta);
        hevm.warp(eta);
        pause.abandonTransaction(usr, codeHash, parameters, eta);

        pause.scheduleTransaction(usr, codeHash, parameters, now + pause.delay());
        bytes32 id = keccak256(abi.encode(usr, codeHash, parameters, now + pause.delay()));
        assertTrue(pause.scheduledTransactions(id));
    }
}

contract Execute is Test {

    function testFail_delay_not_passed() public {
        address      usr = target;
        bytes32      codeHash = extcodehash(usr);
        bytes memory parameters = abi.encode(0);
        uint         eta = now + pause.delay();

        pause.scheduleTransaction(usr, codeHash, parameters, eta);
        pause.executeTransaction(usr, codeHash, parameters, eta);
    }

    function testFail_double_execution() public {
        address      usr = target;
        bytes32      codeHash = extcodehash(usr);
        bytes memory parameters = abi.encodeWithSignature("get()");
        uint         eta = now + pause.delay();

        pause.scheduleTransaction(usr, codeHash, parameters, eta);
        hevm.warp(eta);
        pause.executeTransaction(usr, codeHash, parameters, eta);
        pause.executeTransaction(usr, codeHash, parameters, eta);
    }

    function testFail_execution_too_late() public {
        address      usr = target;
        bytes32      codeHash = extcodehash(usr);
        bytes memory parameters = abi.encodeWithSignature("get()");
        uint         eta = now + pause.delay();

        pause.scheduleTransaction(usr, codeHash, parameters, eta);
        hevm.warp(eta + pause.EXEC_TIME());
        pause.executeTransaction(usr, codeHash, parameters, eta);
    }

    function testFail_codeHash_mismatch() public {
        address      usr = target;
        bytes32      codeHash = bytes32("INCORRECT_CODEHASH");
        bytes memory parameters = abi.encodeWithSignature("get()");
        uint         eta = now + pause.delay();

        pause.scheduleTransaction(usr, codeHash, parameters, eta);
        hevm.warp(eta);
        pause.executeTransaction(usr, codeHash, parameters, eta);
    }

    function testFail_exec_plan_with_proxy_ownership_change() public {
        address      usr = target;
        bytes32      codeHash = extcodehash(usr);
        bytes memory parameters = abi.encodeWithSignature("give(address)", address(this));
        uint         eta = now + pause.delay();

        pause.scheduleTransaction(usr, codeHash, parameters, eta);
        hevm.warp(eta);
        pause.executeTransaction(usr, codeHash, parameters, eta);
    }

    function test_succeeds_when_delay_passed() public {
        address      usr = target;
        bytes32      codeHash = extcodehash(usr);
        bytes memory parameters = abi.encodeWithSignature("get()");
        uint         eta = now + pause.delay();

        pause.scheduleTransaction(usr, codeHash, parameters, eta);
        hevm.warp(eta);
        bytes memory out = pause.executeTransaction(usr, codeHash, parameters, eta);

        assertEq(b32(out), bytes32("Hello"));
    }

    function test_succeeds_when_called_from_unauthorized() public {
        address      usr = target;
        bytes32      codeHash = extcodehash(usr);
        bytes memory parameters = abi.encodeWithSignature("get()");
        uint         eta = now + pause.delay();

        pause.scheduleTransaction(usr, codeHash, parameters, eta);
        hevm.warp(eta);

        bytes memory out = stranger.executeTransaction(pause, usr, codeHash, parameters, eta);
        assertEq(b32(out), bytes32("Hello"));
    }

    function test_succeeds_when_called_from_authorized() public {
        address      usr = target;
        bytes32      codeHash = extcodehash(usr);
        bytes memory parameters = abi.encodeWithSignature("get()");
        uint         eta = now + pause.delay();

        pause.scheduleTransaction(usr, codeHash, parameters, eta);
        hevm.warp(eta);

        bytes memory out = pause.executeTransaction(usr, codeHash, parameters, eta);
        assertEq(b32(out), bytes32("Hello"));
    }
}

contract Abandon is Test {

    function testFail_call_from_unauthorized() public {
        address      usr = target;
        bytes32      codeHash = extcodehash(usr);
        bytes memory parameters = abi.encodeWithSignature("get()");
        uint         eta = now + pause.delay();

        pause.scheduleTransaction(usr, codeHash, parameters, eta);
        hevm.warp(eta);

        stranger.abandonTransaction(pause, usr, codeHash, parameters, eta);
    }

    function test_abandon_scheduled_tx() public {
        address      usr = target;
        bytes32      codeHash = extcodehash(usr);
        bytes memory parameters = abi.encodeWithSignature("get()");
        uint         eta = now + pause.delay();

        pause.scheduleTransaction(usr, codeHash, parameters, eta);

        hevm.warp(eta);
        pause.abandonTransaction(usr, codeHash, parameters, eta);

        bytes32 id = keccak256(abi.encode(usr, codeHash, parameters, eta));
        assertTrue(!pause.scheduledTransactions(id));
    }

    function testFail_abandon_unscheduled_transaction() public {
        address      usr = target;
        bytes32      codeHash = extcodehash(usr);
        bytes memory parameters = abi.encodeWithSignature("get()");
        uint         eta = now + pause.delay();

        // pause.scheduleTransaction(usr, codeHash, parameters, eta);
        hevm.warp(eta);

        pause.abandonTransaction(usr, codeHash, parameters, eta);
    }
}
