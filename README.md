<h1 align="center">
ds-pause
</h1>

<p align="center">
<i><code>delegatecall</code> based proxy with an enforced delay</i>
</p>

`ds-pause` allows authorized users to schedule function calls that can only be executed once some
predetermined waiting period has elapsed. The configurable `delay` attribute sets the minimum wait
time.

`ds-pause` is designed to be used as a component in a governance system, to give affected parties
time to respond to decisions. If those affected by governance decisions have e.g. exit or veto
rights, then the pause can serve as an effective check on governance power.

## Plans

A `scheduledTransaction` describes a single `delegatecall` operation and a unix timestamp `earliestExecutionTime` before which it cannot be executed.

A `scheduledTransaction` consists of:

- `usr`: address to `delegatecall` into
- `codeHash`: the expected codehash of `usr`
- `parameters`: `calldata` to use
- `earliestExecutionTime`: first possible time of execution (as seconds since unix epoch)

Each scheduled tx has a unique id, defined as `keccack256(abi.encode(usr, codeHash, parameters, earliestExecutionTime))`

## Operations

Plans can be manipulated in the following ways:

- **`scheduleTransaction`**: create a `scheduledTransaction`
- **`executeTransaction`**: execute a `scheduledTransaction`
- **`abandonTransaction`**: cancel a `scheduledTransaction`

## Invariants

A break of any of the following would be classified as a critical issue. Please submit bug reports
to security@dapp.org.

**high level**
- There is no way to bypass the delay
- The code executed by the `delegatecall` cannot directly modify storage on the pause
- The pause will always retain ownership of it's `proxy`

**admin**
- `authority`, `owner`, and `delay` can only be changed if an authorized user creates a `scheduledTransaction` to do so

**`scheduledTransactions`**
- A `scheduledTransaction` can only be plotted if its `earliestExecutionTime` is after `block.timestamp + delay`
- A `scheduledTransaction` can only be plotted by authorized users

**`executeTransaction`**
- A `scheduledTransaction` can only be executed if it has previously been plotted
- A `scheduledTransaction` can only be executed once it's `earliestExecutionTime` has passed
- A `scheduledTransaction` can only be executed if its `codeHash` matches `extcodehash(usr)`
- A `scheduledTransaction` can only be executed once
- A `scheduledTransaction` can be executed by anyone

**`abandonTransaction`**
- A `scheduledTransaction` can only be dropped by authorized users

## Identity & Trust

In order to protect the internal storage of the pause from malicious writes during `scheduledTransaction` execution,
we perform the actual `delegatecall` operation in a seperate contract with an isolated storage
context (`DSPauseProxy`). Each pause has it's own individual `proxy`.

This means that `scheduledTransactions` are executed with the identity of the `proxy`, and when integrating the
pause into some auth scheme, you probably want to trust the pause's `proxy` and not the pause
itself.

## Example Usage

```solidity
// construct the pause

uint delay            = 2 days;
address owner         = address(0);
DSAuthority authority = new DSAuthority();

DSPause pause = new DSPause(delay, owner, authority);

// plot the scheduledTransaction

address      usr = address(0x0);
bytes32      codeHash;  assembly { codeHash := extcodehash(usr) }
bytes memory parameters = abi.encodeWithSignature("sig()");
uint         earliestExecutionTime = now + delay;

pause.scheduleTransaction(usr, codeHash, parameters, earliestExecutionTime);
```

```solidity
// wait until block.timestamp is at least now + delay...
// and then execute the scheduledTransaction

bytes memory out = pause.executeTransaction(usr, codeHash, parameters, earliestExecutionTime);
```

## Tests

- [`pause.t.sol`](./pause.t.sol): unit tests
- [`integration.t.sol`](./integration.t.sol): usage examples / integation tests
