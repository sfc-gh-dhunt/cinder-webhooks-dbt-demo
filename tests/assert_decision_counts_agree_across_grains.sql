/*
    Decision volume must agree between the decision fact and the fractional allocation in
    the policy fact.

    Summing `decision_count_allocated` across all policy rows must return the number of
    decisions that applied at least one policy. If it does not, either the allocation
    denominator is wrong or a policy row has gone missing — and the symptom would be a
    policy distribution that does not add up to the decision total, which is the single most
    common way a dimensional model loses credibility with its users.

    Decisions applying no policy are excluded, since they contribute no policy rows to
    allocate.
*/

with decision_total as (

    select count(*) as expected_decisions
    from {{ ref('fct_decisions') }}
    where policy_count > 0

),

allocated_total as (

    select sum(decision_count_allocated) as allocated_decisions
    from {{ ref('fct_decision_policies') }}

)

select
      d.expected_decisions
    , a.allocated_decisions
    , abs(d.expected_decisions - a.allocated_decisions) as difference
from decision_total d
cross join allocated_total a
-- Floating-point allocation cannot be compared exactly: a decision split three ways gives
-- three values of 0.333... that do not sum to precisely 1. The tolerance is scaled to the
-- row count rather than fixed, so it stays meaningful as the data grows.
where abs(d.expected_decisions - a.allocated_decisions) > greatest(0.01, d.expected_decisions * 0.0001)
