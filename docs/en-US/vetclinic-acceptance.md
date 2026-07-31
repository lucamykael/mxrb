# VetClinic end-to-end acceptance

The acceptance project was deleted and rebuilt from `mxrb init`, exercising
every scaffold before adding business rules. Its Mendix 11.12.1 MPR passed
MXRB validation and lint, architecture evaluation, official `mx check`,
`mxbuild`, and a synchronized Runtime functional test.

The regression suite passed 622 examples with 100% line and branch coverage;
RuboCop reported no offenses. The model covers enumerations, six business
entities, `System.User` generalization, system members, access rules, indexes,
N:1, N:N, and 1:1 associations, flows, a page, navigation, and a scheduled
event.

Scaffolds provide structure rather than business requirements: attributes,
flow behavior, widgets, permissions, endpoints, tests, and evaluations remain
project work. The accepted VetClinic had its navigation edited in `project.rb`;
`init` now creates a minimal profile, layout, and Home page, while additional
menu items still have no dedicated command. Published
REST, consumed REST, and Java Action scaffolds are buildable microflow adapters;
native documents still require an exported baseline or Studio Pro.

An independent empty-project smoke test passed `mxrb validate`, official
`mx check`, and MxBuild without manual editing.
