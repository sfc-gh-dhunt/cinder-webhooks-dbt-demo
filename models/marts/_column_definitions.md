{# =====================================================================================
   Shared column definitions
   =====================================================================================
   Definitions for columns that appear in more than one mart, written once here and
   referenced from models/marts/schema.yml with `{{ doc('...') }}`.

   WHY THESE AND NOT EVERY COLUMN. A doc block earns its keep when the same definition is
   needed in more than one place. Keys are the clear case: `queue_key` means the same thing
   on the dimension that owns it and on the three facts that point at it, and writing it
   four times is four chances to describe it four different ways. A column that appears in
   exactly one model is better documented inline in schema.yml, where it sits next to the
   thing it describes.

   These blocks also reach the semantic view. dbt renders `doc()` into the manifest at parse
   time, and macros/semantic/doc_comment.sql reads the rendered description from the
   manifest — so editing a definition here changes both the dbt docs and the Cortex Analyst
   comment, from one edit.
   ===================================================================================== #}


{% docs col_queue_key %}
Surrogate key for the review queue. Generated from the queue slug, which is the only queue
identifier the webhooks carry.
{% enddocs %}


{% docs col_policy_key %}
Surrogate key for the moderation policy. Generated from the policy id as sent by Cinder.
{% enddocs %}


{% docs col_reviewer_key %}
Surrogate key for the human moderator. Generated from the lowercased email, because the
webhook surface has no user id. Null wherever no person was involved — automated decisions
and workflow-driven actions — rather than pointing at a synthetic member.
{% enddocs %}


{% docs col_entity_key %}
Surrogate key for the entity under review. Generated from the entity id and its schema
together, because ids are only unique within a schema.
{% enddocs %}


{% docs col_workflow_key %}
Surrogate key for the automation workflow that acted. Null for actions taken by a person.
{% enddocs %}


{% docs col_decision_sk %}
Surrogate key for a single decision on a job. The join key between the decision grain and
the policy-application grain beneath it.
{% enddocs %}


{% docs col_policy_group_name %}
Always-usable grouping label: the parent policy's name where known, otherwise the policy's
own name. Prefer this over the policy name when reporting distribution — leaf-level
policies fragment into unreadably thin slices, and this never leaves a null bucket.
{% enddocs %}


{% docs col_handle_time_hours %}
Hours from job creation to the decision being recorded. The measure meant by "handle time"
when comparing queues and moderators. Null rather than zero when creation time is absent.
Heavily right-skewed, so a median describes it better than a mean.
{% enddocs %}
