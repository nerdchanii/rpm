## Context

RPM needs a deterministic queue for scheduled issue work.

## Research

Project #7 is the local research inventory, and open issue lifecycle labels are
the Cloud execution queue.

## Contract

The selection command is read-only and returns one machine-readable event.

## Initial scope

Add the queue selector and its deterministic tests.

## Done criteria

- The selected issue order is stable.
- A queue with no matching issue returns `no-work`.

## Related work

None.

## Unresolved decisions

None.
