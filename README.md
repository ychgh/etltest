# ETL Dev/Test Machine in the Cloud

A practical guide and infrastructure-as-code repository for setting up cloud-based development machines — from GPU-powered local LLM rigs to lean CPU-only instances with cloud LLMs.

## Overview

This repository covers three progressive action plans, each targeting a different balance of cost, capability, and convenience:

| Plan | Goal | Approach | Est. Monthly Cost |
|------|------|----------|-------------------|
| **[Plan A](docs/action-plan-a.md)** | Best Local LLM for Coding | GPU cloud instance running local LLMs (Qwen2.5, DeepSeek, CodeLlama) | $200–$800+ |
| **[Plan B](docs/action-plan-b.md)** | CPU Dev Machine + Cloud LLM | Powerful CPU instance (32–64 GB RAM) + OpenCode Zen or GitHub Copilot | $50–$150 |
| **[Plan C](docs/action-plan-c.md)** | Cost-Optimised Spot Instance | Spot instance + auto-shutdown + cloud LLM subscription | **$20–$30** |

## Quick Start

Each plan has both **shell scripts** and an optional **AWS CDK** implementation.

```bash
# Plan B – launch a CPU dev machine
cd scripts/plan-b
./launch.sh

# Plan C – launch a cost-optimised spot instance
cd scripts/plan-c
./launch-spot.sh
```

## Repository Structure

```
.
├── docs/
│   ├── best-local-llm-guide.md   # Comprehensive guide: Best Local LLMs for Coding
│   ├── action-plan-a.md          # Plan A: GPU cloud machine for local LLMs
│   ├── action-plan-b.md          # Plan B: CPU machine + cloud LLM
│   └── action-plan-c.md          # Plan C: Spot instance + budget breakdown
├── scripts/
│   ├── plan-a/                   # Scripts for Plan A (GPU instance)
│   ├── plan-b/                   # Scripts for Plan B (CPU + cloud LLM)
│   └── plan-c/                   # Scripts for Plan C (spot + auto-shutdown)
└── cdk/                          # AWS CDK TypeScript implementation (all plans)
```

## Background Reading

- [Best Local LLM for Coding – Comprehensive Guide](docs/best-local-llm-guide.md)
- [AWS EC2 Spot Pricing](https://aws.amazon.com/ec2/spot/pricing/)
- [OpenCode.ai](https://opencode.ai/)
- [GitHub Copilot Pricing](https://github.com/features/copilot)
