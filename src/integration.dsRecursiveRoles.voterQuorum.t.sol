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
import {DSToken} from "ds-token/token.sol";
import {DSProxy} from "ds-proxy/proxy.sol";
import {DSRoles} from "ds-roles/roles.sol";
import {VoteQuorum, VoteQuorumFactory} from "ds-vote-quorum/VoteQuorum.sol";

import "./pause.sol";

// ------------------------------------------------------------------
// Test Harness
// ------------------------------------------------------------------

abstract contract Hevm {
    function warp(uint) virtual public;
}

contract Voter {
    function vote(VoteQuorum voteQuorum, address proposal) public {
        address[] memory votes = new address[](1);
        votes[0] = address(proposal);
        voteQuorum.vote(votes);
    }

    function electCandidate(VoteQuorum voteQuorum, address proposal) external {
        voteQuorum.electCandidate(proposal);
    }

    function addVotingWeight(VoteQuorum voteQuorum, uint amount) public {
        DSToken gov = voteQuorum.PROT();
        gov.approve(address(voteQuorum));
        voteQuorum.addVotingWeight(amount);
    }

    function removeVotingWeight(VoteQuorum voteQuorum, uint amount) public {
        DSToken iou = voteQuorum.IOU();
        iou.approve(address(voteQuorum));
        voteQuorum.removeVotingWeight(amount);
    }
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
// Gov Proposal Template
// ------------------------------------------------------------------

contract Proposal {
    bool public plotted  = false;

    DSPause public pause;
    address public usr;
    bytes32 public codeHash;
    bytes   public parameters;
    uint    public earliestExecutionTime;

    constructor(DSPause pause_, address usr_, bytes32 codeHash_, bytes memory parameters_) public {
        pause = pause_;
        codeHash = codeHash_;
        usr = usr_;
        parameters = parameters_;
        earliestExecutionTime = 0;
    }

    function scheduleTransaction() external {
        require(!plotted);
        plotted = true;

        earliestExecutionTime = now + pause.delay();
        pause.scheduleTransaction(usr, codeHash, parameters, earliestExecutionTime);
    }

    function executeTransaction() external returns (bytes memory) {
        require(plotted);
        return pause.executeTransaction(usr, codeHash, parameters, earliestExecutionTime);
    }
}

// ------------------------------------------------------------------
// Shared Test Setup
// ------------------------------------------------------------------

contract Test is DSTest {
    // test harness
    Hevm hevm;
    VoteQuorumFactory voteQuorumFactory;
    Target target;
    Voter voter;

    // pause timings
    uint delay = 1 days;

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
        voter = new Voter();

        // create gov token
        gov = new DSToken("PROT");
        gov.mint(address(voter), votes);
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

contract Voting is Test {

    function test_simple_proposal() public {

        // DSRoles
        DSRoles roles = new DSRoles();

        // create gov system
        VoteQuorum voteQuorum = voteQuorumFactory.newVoteQuorum(gov, maxSlateSize);
        DSPause pause = new DSPause(delay, msg.sender, roles);

        // adding roles
        roles.setRootUser(address(voteQuorum), true);

        target.addAuthorization(address(pause.proxy()));
        target.removeAuthorization(address(this));

        // create proposal
        address      usr = address(new SimpleAction());
        bytes32      codeHash = extcodehash(usr);
        bytes memory parameters = abi.encodeWithSignature("executeTransaction(address)", target);

        Proposal proposal = new Proposal(pause, usr, codeHash, parameters);

        // granting access to the proposal contract is needed in order to for it to succeed
        // this can be done in a more granular way (providing access only to schedule and execute tx)
        roles.setRootUser(address(proposal), true);

        // make proposal the hat
        voter.addVotingWeight(voteQuorum, votes);
        voter.vote(voteQuorum, address(proposal));
        voter.electCandidate(voteQuorum, address(proposal));

        // schedule proposal
        proposal.scheduleTransaction();

        // wait until earliestExecutionTime
        hevm.warp(proposal.earliestExecutionTime());

        // execute proposal
        assertEq(target.val(), 0);
        proposal.executeTransaction();
        assertEq(target.val(), 1);
    }

}

// ------------------------------------------------------------------
// Test VoteQuorum Upgrades
// ------------------------------------------------------------------

contract SetAuthority {
    function set(DSAuth usr, DSAuthority authority) public {
        usr.setAuthority(authority);
    }
}

// Temporary DSAuthority that will give a VoteQuorum authority over a pause only
// when a prespecified amount of protocol tokens have been locked in the new vote quorum
contract Guard is DSAuthority {
    // --- data ---
    DSPause public pause;
    VoteQuorum public voteQuorum; // new vote quorum
    uint public limit; // min locked protocol tokens in new vote quorum

    bool public scheduled = false;

    address public usr;
    bytes32 public codeHash;
    bytes   public parameters;
    uint    public earliestExecutionTime;

    // --- init ---

    constructor(DSPause pause_, VoteQuorum voteQuorum_, uint limit_) public {
        pause = pause_;
        voteQuorum = voteQuorum_;
        limit = limit_;

        usr = address(new SetAuthority());
        codeHash = extcodehash(usr);
        parameters = abi.encodeWithSignature("set(address,address)", pause, voteQuorum);
    }

    // --- auth ---

    function canCall(address src, address dst, bytes4 sig) override public view returns (bool) {
        require(src == address(this));
        require(dst == address(pause));
        require(sig == bytes4(keccak256("scheduleTransaction(address,bytes32,bytes,uint256)")));
        return true;
    }

    // --- unlock ---

    function scheduleTransaction() external {
        require(voteQuorum.PROT().balanceOf(address(voteQuorum)) >= limit);
        require(!scheduled);
        scheduled = true;

        earliestExecutionTime = now + pause.delay();
        pause.scheduleTransaction(usr, codeHash, parameters, earliestExecutionTime);
    }

    function executeTransaction() external returns (bytes memory) {
        require(scheduled);
        return pause.executeTransaction(usr, codeHash, parameters, earliestExecutionTime);
    }

    // --- util ---

    function extcodehash(address who) internal view returns (bytes32 soul) {
        assembly { soul := extcodehash(who) }
    }
}


contract UpgradeVoteQuorum is Test {

    function test_quorum_upgrade() public {
        // create gov system
        VoteQuorum oldVoteQuorum = voteQuorumFactory.newVoteQuorum(gov, maxSlateSize);
        DSPause pause = new DSPause(delay, address(0x0), oldVoteQuorum);

        // make pause the only owner of the target
        target.addAuthorization(address(pause.proxy()));
        target.removeAuthorization(address(this));

        // create new quorum
        VoteQuorum newVoteQuorum = voteQuorumFactory.newVoteQuorum(gov, maxSlateSize);

        // create guard
        Guard guard = new Guard(pause, newVoteQuorum, votes);

        // create gov proposal to transfer ownership from the old quorum to the guard
        address      usr = address(new SetAuthority());
        bytes32      codeHash = extcodehash(usr);
        bytes memory parameters = abi.encodeWithSignature("set(address,address)", pause, guard);

        Proposal proposal = new Proposal(pause, usr, codeHash, parameters);

        // check that the old quorum is the authority
        assertEq(address(pause.authority()), address(oldVoteQuorum));

        // vote for proposal
        voter.addVotingWeight(oldVoteQuorum, votes);
        voter.vote(oldVoteQuorum, address(proposal));
        voter.electCandidate(oldVoteQuorum, address(proposal));

        // transfer ownership from old quorum to guard
        proposal.scheduleTransaction();
        hevm.warp(proposal.earliestExecutionTime());
        proposal.executeTransaction();

        // check that the guard is the authority
        assertEq(address(pause.authority()), address(guard));

        // move protocol tokens from old quorum to new quorum
        voter.removeVotingWeight(oldVoteQuorum, votes);
        voter.addVotingWeight(newVoteQuorum, votes);

        // plot transaction to transfer ownership from guard to newVoteQuorum
        guard.scheduleTransaction();
        hevm.warp(guard.earliestExecutionTime());
        guard.executeTransaction();

        // check that the new quorum is the authority
        assertEq(address(pause.authority()), address(newVoteQuorum));
    }

}
