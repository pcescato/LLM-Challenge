# LLM-Challenge

A reproducible benchmark comparing 8 AI coding agent/model combinations on the same real-world project.

## What this is

This repository contains the complete artifacts from a benchmark where 8 different AI coding agent/model combinations were tasked with building the same VPS management toolkit. The goal was to measure code quality, architecture decisions, and production readiness across different tools and models under identical conditions.

This is not a marketing comparison. A real project with concrete requirements was used as the test subject, and the results were evaluated by an external reviewer who had no knowledge of which tool or model produced which implementation.

## The protocol

The benchmark followed a two-phase protocol:

**Phase 1: Architecture**
All tools received the same functional brief and were asked to produce an architecture document. No code was written in this phase.

**Phase 2: Implementation**
All tools received the same development prompt and were asked to implement the VPS manager based on their architecture document.

**Phase 3: Blind review**
All implementations were reviewed by an external reviewer (Qwen 3.7 Plus) who had no knowledge of which tool or model produced which code. The review used a scoring grid with 5 criteria, each scored 1-5, for a maximum of 25 points.

## Combinations tested

| Tool | Model |
|---|---|
| Claude Code | Haiku 4.5 |
| Copilot CLI | Haiku 4.5 |
| OpenCode | Haiku 4.5 |
| OpenCode | GLM 5.2 |
| OpenCode | BigPickle (free) |
| OpenCode | Gemini 3.1 Pro |
| OpenCode | DeepSeek V4 Pro |
| OpenCode | GPT-OSS-120B |

## Results

| Alias | Model | Tool | Score | Total cost | Production-ready |
|---|---|---|---|---|---|
| A | BigPickle | OpenCode | 15/25 | $0 | No |
| B | Haiku 4.5 | Claude Code | 12/25 | Pro sub | No |
| C | GLM 5.2 | OpenCode | 25/25 | $1.73 | Yes |
| D | DeepSeek V4 Pro | OpenCode | 12/25 | $0.24 | No |

The scoring grid and detailed code analysis are available in the `review/` directory.

## Reproducing this benchmark

To reproduce this benchmark with different tools or models:

1. Review the functional brief in `briefs/functional-brief.md`. This is the project specification that was given to all tools.

2. Review the development prompt in `briefs/dev-prompt.md`. This is the phase 2 prompt that instructed tools to implement the project.

3. Run phase 1: Give the functional brief to your tool/model combination and collect the architecture document.

4. Run phase 2: Give the development prompt and the architecture document from phase 1 to the same tool/model combination and collect the implementation.

5. Run phase 3: Submit all implementations to an external reviewer using the scoring grid in `review/scoring-grid.md`. The reviewer should not know which tool or model produced which implementation.

6. Compare scores using the same criteria.

The VPS manager implementations target Ubuntu 24.04 and include Caddy, PHP-FPM, MariaDB/PostgreSQL, Valkey, and FastAPI.

## Article

This benchmark was published as an article. [article link]
