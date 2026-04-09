# AWS CDK Infrastructure (TypeScript)

This CDK app deploys the three dev machine plans as CloudFormation stacks.

## Prerequisites

```bash
# Install dependencies
npm install

# Bootstrap CDK (once per account/region)
npx cdk bootstrap aws://<ACCOUNT_ID>/<REGION>
```

## Deploy

```bash
# Plan A: GPU machine for local LLMs
npm run deploy:plan-a

# Plan B: CPU machine + cloud LLM
npm run deploy:plan-b

# Plan C: Cost-optimised spot instance (recommended)
npm run deploy:plan-c
```

## Destroy

```bash
npm run destroy:plan-a
npm run destroy:plan-b
npm run destroy:plan-c
```

## Customise

Edit `bin/etltest-cdk.ts` to override defaults:

```typescript
// Plan B with 64 GB RAM and spot pricing
new PlanBCpuStack(app, 'PlanBCpuStack', {
  env,
  instanceType: new ec2.InstanceType('r5.2xlarge'),  // 64 GB
  useSpot: true,
});

// Plan C with budget instance (16 GB)
new PlanCSpotStack(app, 'PlanCSpotStack', {
  env,
  instanceType: new ec2.InstanceType('m5.xlarge'),   // 16 GB
  volumeSizeGb: 30,
});
```

## Stacks

| Stack | File | Description |
|-------|------|-------------|
| `PlanAGpuStack` | `lib/plan-a-stack.ts` | GPU spot instance + Ollama + local LLM |
| `PlanBCpuStack` | `lib/plan-b-stack.ts` | CPU dev machine + GitHub Copilot/OpenCode |
| `PlanCSpotStack` | `lib/plan-c-stack.ts` | Cost-optimised spot + CloudWatch auto-stop |
