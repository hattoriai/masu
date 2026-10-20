# Security

## Reporting a vulnerability

Do not open a public issue for a security problem. Report it privately
through GitHub: [Report a vulnerability](https://github.com/hattoriai/masu/security/advisories/new).

Say what an attacker can do, and how: the grid, the source or the event,
and the steps or the payload. We answer within a week, agree on a fix and
a date, and credit you in the advisory unless you ask us not to.

## Supported versions

Security fixes are made to the latest release. Masu is before 1.0, so a
fix is not backported to an earlier minor version.

## What is in scope

Masu runs in your LiveView and takes events from the browser, which any
person can craft. A problem is in scope when such an event can:

- show, change or delete rows that the grid's source does not give the
  person;
- reach another person's views, edits or presence;
- crash the LiveView, or make the server or the database do unbounded
  work.

What a grid shows is decided by its source: scoping the source to the
person is the app's job (see the guides on sources and views).
