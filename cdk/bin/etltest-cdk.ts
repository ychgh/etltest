#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { PlanAGpuStack } from '../lib/plan-a-stack';
import { PlanBCpuStack } from '../lib/plan-b-stack';
import { PlanCSpotStack } from '../lib/plan-c-stack';

const app = new cdk.App();

const env = {
  account: process.env.CDK_DEFAULT_ACCOUNT,
  region: process.env.CDK_DEFAULT_REGION ?? 'us-east-1',
};

// Plan A: GPU dev machine for local LLMs
new PlanAGpuStack(app, 'PlanAGpuStack', {
  env,
  description: 'Plan A: GPU cloud dev machine for local LLM inference (Qwen2.5, DeepSeek, CodeLlama)',
});

// Plan B: CPU dev machine + cloud LLM subscription
new PlanBCpuStack(app, 'PlanBCpuStack', {
  env,
  description: 'Plan B: CPU-only EC2 dev machine + GitHub Copilot / OpenCode Zen',
});

// Plan C: Cost-optimised spot instance + auto-shutdown
new PlanCSpotStack(app, 'PlanCSpotStack', {
  env,
  description: 'Plan C: Spot instance + auto-shutdown + cloud LLM (~$20-30/month)',
});
