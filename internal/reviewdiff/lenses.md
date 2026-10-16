## Correctness
- Does the change do what the intent asks, including its edge cases?
- What happens on empty, missing or malformed input?
- Are errors handled, or returned with enough context to act on?
- Can two runs, two processes or a retry interleave badly here?
- Does anything that used to work now behave differently?
## Tests
- Does every new branch of behaviour have a test that fails without it?
- Do the tests check results, not only that the code ran?
- Are the failure and edge paths tested, not just the happy path?
- Would a test still pass if the change were reverted?
## Security
- Is input from files, the network or another process validated before use?
- Can a path, command or query be steered by untrusted text?
- Are secrets kept out of logs, errors and the repository?
- Does the change widen what runs without the owner's approval?
## Simplicity
- Is there code here that nothing needs yet?
- Could a smaller change do the same job?
- Does it reuse what the codebase already has instead of a copy?
- Will the next reader understand it without the author?
## House rules
