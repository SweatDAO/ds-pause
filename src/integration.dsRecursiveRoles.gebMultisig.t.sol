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

import {DSTest} from "ds-test/test.sol";
import {DSProxy} from "ds-proxy/proxy.sol";
import {DSToken} from "ds-token/token.sol";
import {DSRecursiveRoles} from "ds-roles/recursive_roles.sol";
import {MultiSigWallet} from "geb-basic-multisig/MultisigWallet.sol";
import {VoteQuorum, VoteQuorumFactory} from "ds-vote-quorum/VoteQuorum.sol";

import "./pause.sol";

// ------------------------------------------------------------------
// Test Harness
// ------------------------------------------------------------------

abstract contract Hevm {
    function warp(uint) virtual public;
}

contract Target {
    mapping (address => uint) public authorizedAccounts;
    function addAuthorization(address usr) public isAuthorized { authorizedAccounts[usr] = 1; }
    function removeAuthorization(address usr) public isAuthorized { authorizedAccounts[usr] = 0; }
    modifier isAuthorized { require(authorizedAccounts[msg.sender] == 1); _; }

    constructor() public {
        authorizedAccounts[msg.sender] = 1;
    }

    uint public val = 0;
    function set(uint val_) public isAuthorized {
        val = val_;
    }
}



// ------------------------------------------------------------------
// Shared Test Setup
// ------------------------------------------------------------------

contract Test is DSTest {
    // test harness
    Hevm hevm;
    Target target;
    MultiSigWallet multisig;
    VoteQuorumFactory voteQuorumFactory;


    // pause timings
    uint delay = 1 days;

    // multisig constants
    address[] owners = [msg.sender];
    uint required = 1;

    // gov constants
    uint votes = 100;
    uint maxSlateSize = 1;

    // gov token
    DSToken gov;

    function setUp() public {
        // init hevm
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(0);

        // create test harness
        target = new Target();

        // create gov token
        gov = new DSToken("PROT");
        // gov.mint(address(voter), votes);
        gov.setOwner(address(0));

        // quorum factory
        voteQuorumFactory = new VoteQuorumFactory();
    }

    function extcodehash(address usr) internal view returns (bytes32 ch) {
        assembly { ch := extcodehash(usr) }
    }
}

// ------------------------------------------------------------------
// Test Simple Voting
// ------------------------------------------------------------------

contract SimpleAction {
    function executeTransaction(Target target) public {
        target.set(1);
    }
}

contract MultisigIntegration is Test {

    function test_simple_proposal() public {

        DSRecursiveRoles roles = new DSRecursiveRoles();
        DSPause pause = new DSPause(delay, msg.sender, roles);
        VoteQuorum voteQuorum = voteQuorumFactory.newVoteQuorum(gov, maxSlateSize);

        roles.setAuthority(voteQuorum);

        target.addAuthorization(address(pause.proxy()));
        target.removeAuthorization(address(this));

        assertEq(target.val(), 0);

        owners.push(address(this));

        multisig = new MultiSigWallet(owners, required);
        roles.setOwner(address(multisig));

        assertEq(multisig.owners(0), msg.sender);
        assertEq(multisig.owners(1), address(this));
        assertEq(multisig.required(), 1);
        assertEq(target.val(), 0);

        // proposal
        address      usr = address(new SimpleAction());
        bytes32      codeHash = extcodehash(usr);
        bytes memory proposalParameters = abi.encodeWithSignature("executeTransaction(address)", target);
        uint earliestExecutionTime = now + delay;


        // packing proposal for pause
        bytes memory parameters = abi.encodeWithSignature("scheduleTransaction(address,bytes32,bytes,uint256)", usr, codeHash, proposalParameters, earliestExecutionTime);        

        // create proposal, automatically executed (only one required approver, see unit tests for tests of quorum)
        multisig.submitTransaction("metadata", address(pause), 0, parameters);

        // execute transaction
        hevm.warp(earliestExecutionTime);
        parameters = abi.encodeWithSignature("executeTransaction(address,bytes32,bytes,uint256)", usr, codeHash, proposalParameters, earliestExecutionTime);        

        multisig.submitTransaction("metadata", address(pause), 0, parameters);
        assertEq(target.val(), 1); // effect of proposal execution
    }

}
