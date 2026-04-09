# Best Local LLM for Coding – Comprehensive Guide (2025)

> The demand for privacy-conscious, resource-efficient, and powerful tools has skyrocketed.
> For developers who want to avoid the latency and privacy concerns of cloud-based APIs,
> choosing the best local LLM for coding is both a practical and strategic decision.

---

## Table of Contents

1. [Why Run a Local LLM for Coding?](#1-why-run-a-local-llm-for-coding)
2. [Top Models at a Glance](#2-top-models-at-a-glance)
3. [Model Deep Dives](#3-model-deep-dives)
4. [Hardware Requirements](#4-hardware-requirements)
5. [Serving Frameworks & Tools](#5-serving-frameworks--tools)
6. [IDE Integration](#6-ide-integration)
7. [Choosing the Right Model for Your Workflow](#7-choosing-the-right-model-for-your-workflow)
8. [Action Plan A – Cloud GPU Dev Machine for Local LLMs](#8-action-plan-a--cloud-gpu-dev-machine-for-local-llms)

---

## 1. Why Run a Local LLM for Coding?

| Benefit | Detail |
|---------|--------|
| **Privacy** | Your code never leaves your machine or VPC |
| **No rate limits** | Run inference 24/7 with no per-request billing |
| **Low latency** | GPU memory bandwidth >> network round-trip for large contexts |
| **Offline capable** | Works in air-gapped or restricted environments |
| **Customisable** | Fine-tune on your codebase, apply LoRA adapters |

---

## 2. Top Models at a Glance

| Model | HumanEval | Spider (SQL) | Recommended VRAM | License |
|-------|-----------|--------------|------------------|---------|
| **Qwen2.5 Coder 7B** | 88.4% | 82.0% | 6–12 GB | Apache 2.0 |
| **Qwen2.5 Coder 14B** | 90.2% | 84.0% | 12–16 GB | Apache 2.0 |
| **Qwen2.5 Coder 32B** | 92.7% | 86.0% | 24–40 GB | Apache 2.0 |
| **DeepSeek Coder V2 Lite (16B)** | 81.1% | 79.5% | 16 GB | DeepSeek License |
| **DeepSeek Coder V2 (236B MoE)** | 90.2% | – | 80–160 GB | DeepSeek License |
| **Codestral 22B (Mistral)** | 81.1% | 76.6% | 12–24 GB | Mistral License |
| **CodeLlama 70B** | ~74% | – | 12–24 GB (Q4) / 40–80 GB | Meta LLAMA 2 |
| **StarCoder2 15B** | 73.7% | – | 8–16 GB | BigCode OpenRAIL-M |

> **HumanEval** = Python code generation (pass@1).  
> **Spider** = complex SQL generation accuracy.  
> All scores at default temperature; quantized models may vary ±2–4%.

---

## 3. Model Deep Dives

### 3.1 Qwen2.5 Coder

Developed by Alibaba Cloud. The standout choice for 2025 across all size tiers.

**Strengths**
- Best-in-class HumanEval for its parameter count
- Excellent fill-in-the-middle (FIM) for autocomplete
- 92 programming languages supported
- 128K context window (32B model)
- Runs efficiently on a single consumer GPU (7B/14B at Q4)

**Weaknesses**
- Training data skews towards popular languages (Python, JS, Java)
- Less tested on niche DSLs compared to CodeLlama

**Best for**: Python, JavaScript, TypeScript, SQL; general-purpose coding assistant.

```bash
# Pull and run via Ollama
ollama run qwen2.5-coder:7b
ollama run qwen2.5-coder:14b
ollama run qwen2.5-coder:32b
```

---

### 3.2 DeepSeek Coder V2

Developed by DeepSeek AI. A Mixture-of-Experts (MoE) model with exceptional multi-language and repo-level capability.

**Strengths**
- 338 programming languages in training data
- 128K context window – ideal for large repos
- Fast inference due to MoE architecture (only a subset of experts activates per token)
- Competitive with GPT-4 on challenging multi-file tasks

**Weaknesses**
- The full 236B model is memory-hungry (requires multiple high-end GPUs)
- "Lite" (16B) is more accessible but lags behind Qwen2.5 7B on pure HumanEval

**Best for**: Multi-language projects, repository-level context, production code generation.

```bash
ollama run deepseek-coder-v2:16b
ollama run deepseek-coder-v2:236b   # requires 80+ GB VRAM
```

---

### 3.3 Codestral 22B (Mistral AI)

Mistral's first code-specialised model. Balances performance and resource usage well.

**Strengths**
- 80+ programming languages
- Strong FIM for in-editor autocomplete
- Good refactoring and bug-finding capability
- More accessible weight size than CodeLlama 70B

**Weaknesses**
- Mistral licence (non-commercial fine-tuning restrictions)
- Falls slightly behind Qwen2.5 14B on Python-heavy benchmarks

**Best for**: Mid-size projects needing broad language coverage; VS Code / Neovim autocomplete.

```bash
ollama run codestral:22b
```

---

### 3.4 CodeLlama 70B

Meta's flagship code model. The go-to for large-scale enterprise codebases.

**Strengths**
- Outstanding Python, C++, Java performance
- Wide ecosystem support (Ollama, llama.cpp, LM Studio, text-generation-webui)
- Multiple variants: Base, Instruct, Python-specialised

**Weaknesses**
- Heavy VRAM requirement (40–80 GB native; 12–24 GB with Q4 quantization, with some quality loss)
- Slower token generation at full precision

**Best for**: Large Python/C++/Java codebases; teams with access to multi-GPU machines.

```bash
ollama run codellama:70b          # ~40 GB VRAM
ollama run codellama:70b-q4_0    # ~24 GB VRAM (quantized)
```

---

## 4. Hardware Requirements

### 4.1 Consumer GPU (Local Workstation)

| GPU | VRAM | Recommended Models |
|-----|------|--------------------|
| RTX 3060 / 4060 | 12 GB | Qwen2.5-Coder 7B, Codestral 22B (Q4) |
| RTX 3090 / 4090 | 24 GB | Qwen2.5-Coder 14B/32B (Q4), CodeLlama 34B |
| RTX 6000 Ada | 48 GB | Qwen2.5-Coder 32B (full), DeepSeek 16B |
| A100 / H100 80 GB | 80 GB | CodeLlama 70B (full), DeepSeek 236B (partial) |

### 4.2 Cloud GPU Instances

| AWS Instance | GPU | VRAM | On-Demand (us-east-1) |
|---|---|---|---|
| g4dn.xlarge | T4 | 16 GB | ~$0.53/hr |
| g4dn.2xlarge | T4 | 16 GB | ~$0.75/hr |
| g5.xlarge | A10G | 24 GB | ~$1.01/hr |
| g5.2xlarge | A10G | 24 GB | ~$1.21/hr |
| g5.12xlarge | 4× A10G | 96 GB | ~$5.67/hr |
| p3.2xlarge | V100 | 16 GB | ~$3.06/hr |
| p3.8xlarge | 4× V100 | 64 GB | ~$12.24/hr |
| p4d.24xlarge | 8× A100 | 320 GB | ~$32.77/hr |

> **Tip**: Spot pricing reduces GPU instance costs by 50–80% for interruptible workloads.

### 4.3 CPU-Only (with quantized models)

For smaller models (≤ 13B) with aggressive quantization (Q4/Q8 GGUF), a CPU-only machine can work — slowly.

| Scenario | CPU Tokens/sec | Model |
|----------|---------------|-------|
| m5.4xlarge (16 vCPU) | ~5–8 t/s | Qwen2.5-Coder 7B Q4 |
| c5.9xlarge (36 vCPU) | ~10–15 t/s | Qwen2.5-Coder 7B Q4 |

CPU inference is viable for occasional queries but not suitable as a primary dev assistant (too slow for autocomplete).

---

## 5. Serving Frameworks & Tools

### Ollama (Recommended for Simplicity)
```bash
# Install
curl -fsSL https://ollama.ai/install.sh | sh

# Pull and serve a model
ollama pull qwen2.5-coder:14b
ollama serve   # starts REST API on localhost:11434
```

### llama.cpp (Maximum Performance Control)
```bash
git clone https://github.com/ggerganov/llama.cpp
cd llama.cpp && make -j$(nproc)
./llama-cli -m models/qwen2.5-coder-14b-q4_k_m.gguf \
    --ctx-size 32768 --n-gpu-layers 40 -i
```

### LM Studio (GUI)
- Desktop app for macOS, Windows, Linux
- One-click model download from Hugging Face
- Built-in OpenAI-compatible server
- URL: https://lmstudio.ai

### vLLM (High-Throughput Production)
```bash
pip install vllm
python -m vllm.entrypoints.openai.api_server \
    --model Qwen/Qwen2.5-Coder-14B-Instruct \
    --tensor-parallel-size 2
```

---

## 6. IDE Integration

### Continue.dev (VS Code / JetBrains)
```json
// ~/.continue/config.json
{
  "models": [
    {
      "title": "Qwen2.5-Coder 14B (local)",
      "provider": "ollama",
      "model": "qwen2.5-coder:14b",
      "contextLength": 32768
    }
  ],
  "tabAutocompleteModel": {
    "title": "Qwen2.5-Coder 7B FIM",
    "provider": "ollama",
    "model": "qwen2.5-coder:7b"
  }
}
```

### Cursor (AI-first editor)
Point Cursor's "Local Model" setting to `http://localhost:11434/v1` (Ollama's OpenAI-compatible endpoint).

### Neovim / vim-llm
```lua
-- lazy.nvim plugin config
{ "huggingface/llm.nvim",
  opts = {
    backend = "ollama",
    model = "qwen2.5-coder:14b",
    url = "http://localhost:11434",
  }
}
```

---

## 7. Choosing the Right Model for Your Workflow

```
Need the absolute best accuracy?
  └─ Yes → Qwen2.5 Coder 32B (need 24-40 GB VRAM)
  └─ No → Continue...

Working with multiple languages or large repos?
  └─ Yes → DeepSeek Coder V2 (16B lite or full 236B)
  └─ No → Continue...

Limited to a consumer GPU (≤16 GB VRAM)?
  └─ Yes → Qwen2.5 Coder 7B or 14B (Q4 quant)
  └─ No → Continue...

Want strong FIM autocomplete for Python/JS?
  └─ Yes → Qwen2.5 Coder 7B (fastest FIM)
  └─ No → Codestral 22B (broader language coverage)
```

---

## 8. Action Plan A – Cloud GPU Dev Machine for Local LLMs

See the dedicated document: **[Action Plan A](action-plan-a.md)**

This plan walks through:
1. Launching a GPU-enabled EC2 spot instance (g5.xlarge or g4dn.xlarge)
2. Setting up Ollama + Qwen2.5-Coder
3. Connecting via SSH and configuring VS Code / Continue.dev tunnel
4. Auto-shutdown and cost controls
5. Tearing down safely

---

*Sources: [Deepgram Local LLM Comparison](https://deepgram.com/learn/best-local-coding-llm), [MarkTechPost Top Local LLMs 2025](https://www.marktechpost.com/2025/07/31/top-local-llms-for-coding-2025/), [Collabnix Ollama Models Guide](https://collabnix.com/best-ollama-models-for-developers-complete-2025-guide-with-code-examples/)*
