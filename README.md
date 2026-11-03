# AutoStopping Automation

Harness pipelines that manage Harness CCM AutoStopping through the Lightwing API: register tag-based onboarding configs, create EC2 rules with fixed uptime schedules, report on existing rules, and delete rules.

All four pipelines are CI stages on Harness Cloud. Each runs one `Run` step in an `alpine:3.20` container that installs `curl` and `jq` and calls `https://app.harness.io/gateway/lw/api/...`.

| Pipeline | Identifier | Writes anything? | Purpose |
|---|---|---|---|
| AutoStopping Onboarding Config | `autostopping_onboarding_config` | Yes | Registers an onboarding config. A Harness background job (hourly) then creates rules for matching instances. |
| AutoStopping Rule Create | `autostopping_rule_create` | Yes | Creates one tag-based EC2 rule and attaches a fixed uptime schedule. |
| AutoStopping Rules Report | `autostopping_rules_report` | No | Lists rules, shows rules on one connector, and finds rules that filter on a given tag. |
| AutoStopping Rule Delete | `autostopping_rule_delete` | Yes | Prints one rule by ID, then deletes it. |

```
pipelines/   Pipeline YAML (import these into Harness)
examples/    Runtime input YAML for each pipeline, ready to run
scripts/     import_pipelines.sh and run_pipeline.sh (Harness REST API helpers)
```

## Prerequisites

1. **A Harness project.** The YAML uses placeholder org `my_org` and project `my_project`. To target your project, change `orgIdentifier` / `projectIdentifier` in each file, or let `scripts/import_pipelines.sh` rewrite them.
2. **Harness Cloud build infrastructure** enabled for CI. The step image is pulled through the built-in `account.harnessImage` Docker connector. No delegate is needed for this; see [Build infrastructure and delegates](#build-infrastructure-and-delegates) if you can't use Harness Cloud.
3. **An API key secret** named `harness_api_key` at account scope. It must hold a Harness API key (PAT or service-account token) with CCM AutoStopping view/create/delete permissions. The pipelines read it with `<+secrets.getValue("account.harness_api_key")>`; change that line in each pipeline if your secret has a different identifier or scope.
4. **A CCM AWS connector with Optimization (AutoStopping) enabled.** The examples use placeholder connector identifier `my_aws_ccm_connector` and display name `my-aws-ccm-connector`; replace both with your connector's values (**Account Settings → Connectors**).

## Build infrastructure and delegates

### Default setup: Harness Cloud, no delegate

Every pipeline in `pipelines/` runs its stage on **Harness Cloud**:

```yaml
- stage:
    type: CI
    spec:
      cloneCodebase: false
      platform:
        os: Linux
        arch: Amd64
      runtime:
        type: Cloud
        spec: {}
```

With this setup you **do not install or select a delegate**:

- Harness starts a short-lived, Harness-hosted Linux VM for each run and deletes it afterwards.
- The `alpine:3.20` step image is pulled from Docker Hub through the built-in `account.harnessImage` connector.
- `account.harness_api_key` is read from the **Harness built-in secret manager**, which Harness Cloud can reach directly.
- The step calls `https://app.harness.io/gateway/lw/api/...` over the public internet. Nothing in your network or cloud account is contacted directly; Harness itself starts/stops the instances through your CCM connector.

### When you need an alternative

Use one of the options below if any of these apply:

- Harness Cloud is not enabled on your account or plan.
- Your security policy requires pipeline steps to run inside your own network.
- Your API key secret is stored in an external secret manager (HashiCorp Vault, AWS Secrets Manager, etc.) that is only reachable through a delegate.
- You cannot pull images from Docker Hub and must use a private registry.

All options use the same script. Only the stage's infrastructure section changes.

### Option 1: Kubernetes cluster with a delegate (CI stage)

The stage runs as a pod in your Kubernetes cluster. A delegate installed in that cluster creates the pod and relays logs to Harness.

1. **Install a delegate in the cluster.** In Harness go to **Project Settings → Delegates → New Delegate → Kubernetes → Helm Chart**, give it a name (e.g. `autostopping-delegate`) and copy the generated command. It looks like this; use the values from the UI, especially the token:

   ```sh
   helm repo add harness-delegate https://app.harness.io/storage/harness-download/delegate-helm-chart/
   helm repo update harness-delegate
   helm upgrade -i autostopping-delegate --namespace harness-delegate-ng --create-namespace \
     harness-delegate/harness-delegate-ng \
     --set delegateName=autostopping-delegate \
     --set accountId=<your account id> \
     --set delegateToken=<token from the UI> \
     --set managerEndpoint=https://app.harness.io \
     --set delegateDockerImage=<image from the UI> \
     --set replicas=1 --set upgrader.enabled=true
   ```

   Wait until the delegate shows **Connected** on the Delegates page.

2. **Create a Kubernetes cluster connector.** **Project Settings → Connectors → New Connector → Kubernetes cluster** → **Use the credentials of a specific Harness Delegate** → select `autostopping-delegate` → **Save and Continue** → **Finish**. Note its identifier, e.g. `my_k8s_connector`.

3. **Change the stage infrastructure** in each pipeline. Replace the `platform:` and `runtime:` blocks with:

   ```yaml
   - stage:
       type: CI
       spec:
         cloneCodebase: false
         infrastructure:
           type: KubernetesDirect
           spec:
             connectorRef: my_k8s_connector
             namespace: harness-delegate-ng
             automountServiceAccountToken: true
             nodeSelector: {}
             os: Linux
   ```

   In the UI: open the stage → **Infrastructure** tab → **Kubernetes** → pick the connector and namespace.

4. **Image access.** The pod pulls `alpine:3.20` and runs `apk add curl jq`, so the cluster needs outbound access to Docker Hub and the Alpine package mirror. If it doesn't have that, build an image with `curl` and `jq` preinstalled, push it to your registry, create a Docker registry connector for it, then set the step's `connectorRef` / `image` to that and delete the `apk add` line.

The pod also needs outbound HTTPS to `app.harness.io`. Full reference: [Set up a Kubernetes cluster build infrastructure](https://developer.harness.io/continuous-integration/use-harness-ci/use-harness-ci/set-up-build-infrastructure/k8s-build-infrastructure).

### Option 2: Run directly on a delegate (Custom stage + Shell Script step)

No build pod and no CI module needed. The script runs inside the delegate process itself. This suits accounts that already have a delegate (Kubernetes or Docker) and don't use Harness CI.

1. Install a delegate as in Option 1, step 1 (or **Docker** instead of Kubernetes), and give it a tag such as `autostopping` (**Delegate → Edit → Tags**).
2. Convert each pipeline's stage from `CI` to `Custom` and the `Run` step to a `ShellScript` step. Skeleton for Rule Create:

   ```yaml
   stages:
     - stage:
         name: Create Rule
         identifier: create_rule
         type: Custom
         spec:
           execution:
             steps:
               - step:
                   type: ShellScript
                   name: Create AutoStopping Rule
                   identifier: create_autostopping_rule
                   timeout: 10m
                   spec:
                     shell: Bash
                     onDelegate: true
                     delegateSelectors:
                       - autostopping
                     source:
                       type: Inline
                       spec:
                         script: |
                           # paste the Run step's command here, minus the "apk add" line
                     environmentVariables:
                       - name: ACCOUNT_ID
                         type: String
                         value: <+account.identifier>
                       - name: API_TOKEN
                         type: String
                         value: <+secrets.getValue("account.harness_api_key")>
                       - name: RULE_NAME
                         type: String
                         value: <+pipeline.variables.RULE_NAME>
                       # ...one entry per variable, same as the Run step's envVariables
                     outputVariables: []
   ```

   The pipeline `variables:` section stays as it is.

3. **`curl` and `jq` on the delegate.** The delegate image ships `curl` but not always `jq`. Either add `jq` to a custom delegate image, or put this at the top of the script so it downloads `jq` when it's missing:

   ```sh
   command -v jq >/dev/null || {
     curl -sSL -o /tmp/jq https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64
     chmod +x /tmp/jq
     export PATH=/tmp:$PATH
   }
   ```

The delegate needs outbound HTTPS to `app.harness.io` (and to `github.com` if you use the `jq` download above).

### Option 3: Self-hosted VM build infrastructure

If you run CI builds on your own VMs (AWS, Azure, GCP or a local machine), set the stage's **Infrastructure** to **VMs** or **Local** and point it at your pool/runner. These also need a delegate plus the Harness runner; follow [Set up build infrastructure](https://developer.harness.io/continuous-integration/use-harness-ci/use-harness-ci/set-up-build-infrastructure) in the Harness docs. The script and step stay unchanged, as long as the VM can run Docker containers and reach Docker Hub and `app.harness.io`.

### Which one to pick

| Situation | Use |
|---|---|
| Harness Cloud available, built-in secret manager | Default (no delegate) |
| Must run in your network, you use Harness CI | Option 1 (Kubernetes) or Option 3 (VMs) |
| No CI module, or you just want the simplest delegate-based setup | Option 2 (Custom stage on a delegate) |
| API key secret in Vault / AWS Secrets Manager behind a delegate | Option 1, 2 or 3, with the secret manager connector using the same delegate |

## Install the pipelines

**Option A, Harness UI:** in the project go to **Pipelines → Create a Pipeline → Import from YAML** (or create an empty pipeline, switch to the YAML view and paste) for each file in `pipelines/`.

**Option B, script:**

```sh
export HARNESS_API_KEY=pat.xxxxx      # key with pipeline create permission
export HARNESS_ACCOUNT_ID=<your account id>
export HARNESS_ORG=my_org
export HARNESS_PROJECT=my_project
scripts/import_pipelines.sh
```

The script POSTs each file to `/pipeline/api/pipelines/v2`. A pipeline that already exists returns an error for that file; edit it in the UI or delete it first.

## How to run a pipeline

Every pipeline takes its settings as **pipeline variables** that are runtime inputs (`<+input>`). You can supply them three ways.

**1. Harness UI:** open the pipeline → **Run** → fill in the variables → **Run Pipeline**. Fields with a default are pre-filled.

**2. Script with an example file:**

```sh
scripts/run_pipeline.sh autostopping_rules_report examples/rules_report.yaml
```

It prints the execution ID and a link to the run. Copy an example file and edit the values to make your own.

**3. Raw API call:**

```sh
curl -X POST \
  "https://app.harness.io/pipeline/api/pipeline/execute/autostopping_rules_report?accountIdentifier=$HARNESS_ACCOUNT_ID&orgIdentifier=$HARNESS_ORG&projectIdentifier=$HARNESS_PROJECT&moduleType=ci" \
  -H "x-api-key: $HARNESS_API_KEY" \
  -H "Content-Type: application/yaml" \
  --data-binary @examples/rules_report.yaml
```

**Always quote values in input YAML.** Unquoted `yes`, `no`, `true` and `on` are parsed as YAML booleans and Harness rejects them as String variables. Write `value: "yes"`, not `value: yes`.

To see a step's output, open the execution → **Create Rule / Report / Delete Rule** stage → the Run step → **Logs**.

---

## AutoStopping Rules Report

Read-only. Use it before creating anything, to see what already exists.

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `CONNECTOR_ID` | yes | `my_aws_ccm_connector` | CCM connector identifier whose rules are printed in full |
| `TAG_KEY` | yes | `autostopping` | Prints every rule whose definition mentions this tag key |

Example (`examples/rules_report.yaml`):

```yaml
pipeline:
  identifier: autostopping_rules_report
  variables:
    - name: CONNECTOR_ID
      type: String
      value: "my_aws_ccm_connector"
    - name: TAG_KEY
      type: String
      value: "autostopping"
```

Output sections in the log:

1. **Onboarding configs.** Currently returns HTTP 404 `route not found`, because the API has no list endpoint for onboarding configs. This is expected.
2. **All AutoStopping rules (summary).** One tab-separated line per rule: `id  name  kind  connector  disabled  dry_run  status`.
3. **Rules on connector `<CONNECTOR_ID>`.** Full JSON for those rules.
4. **Rules whose definition mentions tag `<TAG_KEY>`.** ID, name, connector and the instance filter.

Known limitation: the list endpoint (`GET /autostopping/rules`) does **not** return rules created through the v2 API, including rules made by the Rule Create pipeline. Check those in **Cloud Costs → AutoStopping Rules** in the UI.

---

## AutoStopping Rule Create

Creates one EC2 rule that selects instances by tag, then attaches a fixed **uptime** schedule. There is no load balancer or proxy, so Harness treats the instances as idle and stops them outside the uptime window. Inside the window they are kept running.

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `RULE_NAME` | yes | | Rule name shown in the UI |
| `CONNECTOR_ID` | yes | `my_aws_ccm_connector` | CCM AWS connector identifier |
| `CONNECTOR_NAME` | yes | `my-aws-ccm-connector` | Connector display name (stored in rule metadata) |
| `TAG_KEY` | yes | | EC2 tag key used to select instances |
| `TAG_VALUE` | yes | | EC2 tag value used to select instances (quote it) |
| `REGION` | yes | `us-east-1` | AWS region of the instances; one region per rule |
| `IDLE_TIME` | yes | `15` | Idle minutes before stopping (number) |
| `DRY_RUN` | yes | `true` | `true` simulates and estimates savings only; `false` really stops instances |
| `SCHEDULE_NAME` | yes | | Name of the uptime schedule |
| `TIME_ZONE` | yes | `Asia/Kolkata` | IANA time zone for the schedule, e.g. `UTC`, `America/New_York` |
| `UPTIME_DAYS` | yes | `1,2,3,4,5` | Comma-separated days, `0`=Sunday … `6`=Saturday |
| `UPTIME_START` | yes | `09:00` | Start of the uptime window, `HH:MM` 24-hour |
| `UPTIME_END` | yes | `18:00` | End of the uptime window, `HH:MM` 24-hour |

**Example 1: 9 AM–6 PM IST on weekdays, dry run** (`examples/rule_create_business_hours_ist.yaml`).
```yaml
pipeline:
  identifier: autostopping_rule_create
  variables:
    - name: RULE_NAME
      type: String
      value: "autostopping-business-hours"
    - name: CONNECTOR_ID
      type: String
      value: "my_aws_ccm_connector"
    - name: CONNECTOR_NAME
      type: String
      value: "my-aws-ccm-connector"
    - name: TAG_KEY
      type: String
      value: "autostopping"
    - name: TAG_VALUE
      type: String
      value: "yes"
    - name: REGION
      type: String
      value: "us-east-1"
    - name: IDLE_TIME
      type: String
      value: "15"
    - name: DRY_RUN
      type: String
      value: "true"
    - name: SCHEDULE_NAME
      type: String
      value: "business-hours-ist"
    - name: TIME_ZONE
      type: String
      value: "Asia/Kolkata"
    - name: UPTIME_DAYS
      type: String
      value: "1,2,3,4,5"
    - name: UPTIME_START
      type: String
      value: "09:00"
    - name: UPTIME_END
      type: String
      value: "18:00"
```

```sh
scripts/run_pipeline.sh autostopping_rule_create examples/rule_create_business_hours_ist.yaml
```

**Example 2: 8 AM–8 PM New York time every day, different tag and region** (`examples/rule_create_us_hours_every_day.yaml`). The values that differ are `TAG_KEY=Schedule`, `TAG_VALUE=us-work-hours`, `REGION=us-west-2`, `IDLE_TIME=30`, `TIME_ZONE=America/New_York`, `UPTIME_DAYS=0,1,2,3,4,5,6`, `UPTIME_START=08:00` and `UPTIME_END=20:00`.

What the step does:

1. Lists rules and looks for one on `CONNECTOR_ID` whose filter already has `TAG_KEY=TAG_VALUE`. If found, it reuses that rule instead of creating one.
2. Otherwise it POSTs `/autostopping/v2/rules` and logs `Created rule <id>`.
3. Lists schedules on the rule and stops if one named `SCHEDULE_NAME` is already attached.
4. Otherwise it POSTs `/schedules` and logs `Attached schedule <id> to rule <id>`.

Things to know:

- **Do not re-run for the same tag.** Because of the list limitation described under the report pipeline, step 1 cannot see rules created by this pipeline, so a re-run creates a duplicate rule. If that happens, delete the extra one with the Delete pipeline.
- **Going live:** create with `DRY_RUN` `"false"`, or turn off dry run on the rule in the UI after checking the simulated savings.
- **A failed schedule step leaves the rule in place.** Fix the inputs, delete the rule (or attach a schedule in the UI), then run again.
- If the onboarding config below is also active for the same tag, it may create its own rule for the same instances. Keep only one.

---

## AutoStopping Rule Delete

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `RULE_ID` | yes | | Numeric rule ID (from the Create log, the Report, or the rule URL in the UI) |

Example (`examples/rule_delete.yaml`):

```yaml
pipeline:
  identifier: autostopping_rule_delete
  variables:
    - name: RULE_ID
      type: String
      value: "12345"
```

```sh
scripts/run_pipeline.sh autostopping_rule_delete examples/rule_delete.yaml
```

The step first GETs `/autostopping/v2/rules/<RULE_ID>` and prints the rule's ID, name, connector, status and tag filter, then calls `DELETE /autostopping/rules/<RULE_ID>`. It fails if the delete returns a non-2xx status. **Deletion is immediate and there is no confirmation**, so check the ID with the Report pipeline or the UI first. Schedules attached to the rule are no longer applied once the rule is gone.

---

## AutoStopping Onboarding Config

Registers an onboarding config. It does not create rules itself: a Harness background job runs about every hour, finds instances on matching connectors that carry the tag, and creates rules for them (up to `RULE_LIMIT`).

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `NAME` | yes | | Config name |
| `KIND` | yes | | Resource kind; `instance` for EC2 |
| `ENABLED` | yes | `true` | Enable the config |
| `CONNECTOR_NAME_REGEX` | no | `.*` | Regex on connector **display names**; `^my-aws-ccm-connector$` matches one connector |
| `ALLOWED_PROVIDERS` | yes | | `aws`, `azure` or `gcp` |
| `TIME_ZONE` | yes | `UTC` | Time zone for schedules |
| `RULE_LIMIT` | yes | `10` | Maximum rules the job may create |
| `DRY_RUN` | yes | `true` | Created rules run in dry-run mode |
| `TAG_KEY` / `TAG_VALUE` | no | empty | Only instances with this tag are onboarded; empty means no tag filter |
| `IDLE_TIME` | yes | `15` | Idle minutes for created rules |
| `DEFAULT_SCHEDULE` | effectively yes | empty | Uptime hours as `start-end`, e.g. `9-17`. The API rejects empty values and day prefixes such as `Mon:9-17` |
| `SCHEDULE_TAG_KEY` | no | empty | Instance tag holding a per-instance schedule, e.g. `EC2Schedule` with value `Mon:9-17.Tue:9-17.Sat:off` |
| `CONNECTOR_NAME_EXCLUDE` | no | empty | Connector names to skip |
| `PATCH_KEY` | no | empty | Tag key for schedule overrides; `patch_schedule` is only sent when this is set |
| `PATCH_VALUE_1` / `PATCH_SCHEDULE_1` | no | empty | First override: instances with `PATCH_KEY=PATCH_VALUE_1` get `PATCH_SCHEDULE_1` |
| `PATCH_VALUE_2` / `PATCH_SCHEDULE_2` | no | empty | Second override; entries with an empty value are dropped |

Example (`examples/onboarding_config_tag.yaml`):

```sh
scripts/run_pipeline.sh autostopping_onboarding_config examples/onboarding_config_tag.yaml
```

Key values in that file: `NAME="aws-autostopping-onboarding"`, `KIND="instance"`, `CONNECTOR_NAME_REGEX="^my-aws-ccm-connector$"`, `ALLOWED_PROVIDERS="aws"`, `TAG_KEY="autostopping"`, `TAG_VALUE="yes"`, `DEFAULT_SCHEDULE="9-17"`, `SCHEDULE_TAG_KEY="EC2Schedule"`, `DRY_RUN="true"`.

The step logs the request body and the API response, and fails on a non-2xx status.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| HTTP 401 from the Lightwing API | Secret doesn't hold a valid key for this account | Put a valid key in `harness_api_key`, or point the pipelines at another secret |
| Step exits with status 2 right after `apk add` | A JSON value (`ENABLED`, `DRY_RUN`, `RULE_LIMIT`, `IDLE_TIME`) isn't valid JSON | Use `true`/`false` and plain numbers |
| `parameter null` / unbound variable errors | Harness doesn't export environment variables whose value is empty | The pipelines already default optional variables; keep that line if you edit the script |
| Run rejected before starting: value is not a string | Unquoted `yes`/`true` in input YAML | Quote every value |
| `default_schedule is required` or invalid schedule | Empty or day-prefixed `DEFAULT_SCHEDULE` | Use `start-end`, e.g. `9-17` |
| `parsing time ... as "2006-01-02T15:04:05Z07:00"` on schedules | Non-RFC 3339 timestamp | Already fixed in Rule Create; keep the `date -u '+%Y-%m-%dT%H:%M:%SZ'` format |
| Duplicate rules after re-running Rule Create | List API doesn't return v2-created rules | Delete the extra rule with Rule Delete |
