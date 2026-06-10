# 5G NR Beam Selection: ML-Based Enhancement

**Course:** ECE 529 Next Generation Mobile Communication Systems  
**Institution:** Abdullah Gül University, Kayseri, Turkey  
**Term:** Spring 2025-26

## Project Overview

This repository contains MATLAB implementations for the course project on ML-based beam selection enhancement for 5G NR mmWave systems. The project reproduces the MathWorks Neural Network for Beam Selection benchmark and proposes three novel architectures to improve Top-K beam selection accuracy.

## Repository Structure
├── NeuralNetworkBeamSelectionExample.m   # Baseline benchmark (MathWorks)
├── Method1_AttentionNN.m                 # Novel Method 1: Attention-Weighted NN
├── Method2_DualOutputNN.m               # Novel Method 2: Dual-Output NN
├── Method3_EnsembleRF_NN.m             # Novel Method 3: RF + NN Ensemble
├── h38901Channel.m                      # Helper: TR 38.901 channel model
├── h38901Scenario.m                     # Helper: scenario configuration
├── hGenData38901Channel.m               # Helper: data generation
├── hGetBeamSweepAngles.m               # Helper: beam sweep angles
├── hPhasedToNRArray.m                   # Helper: antenna array conversion
├── hSSBurstRSRP.m                       # Helper: SSB burst RSRP
├── hSSBurstStartSymbols.m              # Helper: SSB burst timing
├── hSSBurstTimingOffset.m              # Helper: SSB timing offset
├──README.md
├── baseline_topK_accuracy.png
├── method2_topK_accuracy.png
├── method3_topK_accuracy.png
└── baseline_histogram.png

## Dependencies

- MATLAB R2024a or later
- Communications Toolbox
- Deep Learning Toolbox
- Statistics and Machine Learning Toolbox
- Phased Array System Toolbox

## Dataset

The pre-recorded dataset files are required to run the code but are not included in this repository due to file size. Download them from the MathWorks Neural Network for Beam Selection example:

**Link:** https://www.mathworks.com/help/comm/ug/neural-network-for-beam-selection.html

Required files (place in same folder as .m files):
- `nnBS_prm.mat`
- `nnBS_TrainingData.mat`
- `nnBS_TestData.mat`
- `nnBS_trainedNet.mat`

## How to Reproduce Results

**Step 1 — Run the baseline:**
```matlab
run('NeuralNetworkBeamSelectionExample.m')
```
This loads the pre-recorded data and evaluates the baseline NN.
Record the baseline metrics (Top-K accuracy, Average RSRP).

**Step 2 — Run Method 1 (Attention NN):**
```matlab
run('Method1_AttentionNN.m')
```
Trains the attention-weighted neural network (~20 minutes on CPU).

**Step 3 — Run Method 2 (Dual-Output NN):**
```matlab
run('Method2_DualOutputNN.m')
```
Trains the dual-output neural network with regression and 
classification heads (~15 minutes on CPU).

**Step 4 — Run Method 3 (RF + NN Ensemble):**
```matlab
run('Method3_EnsembleRF_NN.m')
```
Trains Random Forest (~3 minutes) and loads Method 2's NN for ensemble.
Requires `method2_dualOutputNN.mat` from Step 3.

## Key Results

| Method | Top-1 | Top-3 | Top-5 | Top-10 | Top-18 |
|--------|-------|-------|-------|--------|--------|
| Baseline NN | 31.86% | 57.57% | 70.86% | 85.00% | 94.43% |
| Method 1: Attention NN | 23.86% | 47.86% | 65.00% | 79.14% | 90.29% |
| Method 2: Dual-Output (Cls) | 30.14% | **58.86%** | 70.71% | **85.00%** | 94.29% |
| Method 2: Dual-Output (Reg) | 27.71% | 56.29% | 69.43% | 84.71% | **94.71%** |
| Method 3: Ensemble | 29.86% | 56.00% | 68.86% | 83.43% | 92.71% |

## Reference

MathWorks Neural Network for Beam Selection:  
https://www.mathworks.com/help/comm/ug/neural-network-for-beam-selection.html
