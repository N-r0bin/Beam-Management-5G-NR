%% Method 1: Attention-Weighted Neural Network for Beam Selection
% Novel contribution: adds a self-attention mechanism before the feedforward
% layers to learn which of the 14 RSRP measurements are most informative.
%
% Architecture:
%   14 RSRP inputs
%   - Attention layer (learns importance weights for each measurement)
%   - Weighted inputs (element-wise multiplication)
%   - Feedforward NN (same structure as baseline: 64-128-256-128)
%   - 70 RSRP predictions
%   - Top-K beam selection
%
% Everything else identical to baseline for fair comparison.

%% ── 1. LOAD DATA (identical to baseline) ────────────────────────────────
filenameParam     = "nnBS_prm.mat";
filenameTrainData = "nnBS_TrainingData.mat";
filenameTestData  = "nnBS_TestData.mat";

load(filenameParam);
load(filenameTrainData);
load(filenameTestData);

%% ── 2. PROCESS DATA (identical to baseline) ─────────────────────────────
optBeamPairIdxScalarTrain = processData(prm, rsrpMatTrain);
optBeamPairIdxScalarTest  = processData(prm, rsrpMatTest);

totalTrainSamples = dataTrain.NumUELocations;
valDataLen        = round(0.1 * totalTrainSamples);

rng(111)
shuffledIdx      = randperm(totalTrainSamples);
rsrpMatTrain     = rsrpMatTrain(:,:,shuffledIdx);
locationMatTrain = dataTrain.PosUE(shuffledIdx, :);

rsrpMatVal           = rsrpMatTrain(:,:,1:valDataLen);
rsrpMatTrainMinusVal = rsrpMatTrain(:,:,valDataLen+1:end);
trainLocs            = locationMatTrain(valDataLen+1:end, :);

%% ── 3. NORMALISE → RESHAPE → DOWNSAMPLE (identical to baseline) ─────────
numBeamPairs    = prm.NumRxBeams * prm.NumTxBeams;   % 70
numSampledBeams = 14;
downsampleStep  = round(numBeamPairs / numSampledBeams);

globalMax = max(abs(rsrpMatTrainMinusVal), [], "all");
globalMax = max(globalMax, eps);
normalize = @(x) x / globalMax;

rsrpMatTrainNorm = normalize(rsrpMatTrainMinusVal);
rsrpMatValNorm   = normalize(rsrpMatVal);
rsrpMatTestNorm  = normalize(rsrpMatTest);

vec = @(x) reshape(x, numBeamPairs, []);

rsrpTrainVec   = vec(rsrpMatTrainNorm);
rsrpTrainInput = rsrpTrainVec(1:downsampleStep:end, :);   % 14 x N_train

rsrpValVec   = vec(rsrpMatValNorm);
rsrpValInput = rsrpValVec(1:downsampleStep:end, :);

rsrpTestVec   = vec(rsrpMatTestNorm);
rsrpTestInput = rsrpTestVec(1:downsampleStep:end, :);

testLocs    = dataTest.PosUE;
testDataLen = size(rsrpMatTestNorm, 3);

%% ── 4. BUILD ATTENTION NN ARCHITECTURE ───────────────────────────────────
% How the attention mechanism works:
%   - A small FC layer takes the 14 inputs and outputs 14 attention scores
%   - Softmax normalizes scores into weights that sum to 1
%   - These weights multiply the original inputs (focus on important ones)
%   - The weighted inputs go into the main feedforward network
%
% This is implemented as a dlnetwork with a custom forward pass below.
% We train the attention weights jointly with the main network weights.

% --- Attention sub-network (learns which inputs matter most) ---
attentionLayers = dlnetwork([...
    featureInputLayer(numSampledBeams, Name="attn_input")
    fullyConnectedLayer(numSampledBeams, Name="attn_fc")
    softmaxLayer(Name="attn_softmax")]);          % outputs 14 weights summing to 1

% --- Main feedforward network (same structure as baseline) ---
mainLayers = dlnetwork([...
    featureInputLayer(numSampledBeams, Name="main_input")
    fullyConnectedLayer(64,  Name="fc1"); reluLayer(Name="relu1")
    fullyConnectedLayer(128, Name="fc2"); reluLayer(Name="relu2")
    fullyConnectedLayer(256, Name="fc3"); reluLayer(Name="relu3")
    fullyConnectedLayer(128, Name="fc4"); reluLayer(Name="relu4")
    fullyConnectedLayer(numBeamPairs, Name="fc_out")
    tanhLayer(Name="tanh_out")]);

disp("Attention NN architecture built successfully.")

%% ── 5. CUSTOM TRAINING LOOP ──────────────────────────────────────────────
% We use a manual training loop because the attention mechanism requires
% a custom forward pass: attention weights × inputs → main network

maxEpochs     = 500;
miniBatchSize = 200;
learnRate     = 1e-4;
numTrainSamples = size(rsrpTrainInput, 2);
numBatches    = floor(numTrainSamples / miniBatchSize);

% Learning rate schedule (same as baseline: drop by 0.8 every 10 epochs)
lrDropPeriod  = 10;
lrDropFactor  = 0.8;

% Adam optimizer parameters
trailingAvgAttn  = []; trailingAvgSqAttn  = [];
trailingAvgMain  = []; trailingAvgSqMain  = [];
gradDecay = 0.9; sqGradDecay = 0.999;

bestValLoss = inf;
iteration   = 0;

fprintf("\nStarting Attention NN training...\n")
fprintf("%-10s %-8s %-15s %-15s\n", "Iteration","Epoch","TrainingLoss","ValidationLoss")
tic

for epoch = 1:maxEpochs

    % Shuffle training data each epoch
    shuffleIdx    = randperm(numTrainSamples);
    XTrainShuffled = rsrpTrainInput(:, shuffleIdx);
    YTrainShuffled = rsrpTrainVec(:,   shuffleIdx);

    % Adjust learning rate
    currentLR = learnRate * (lrDropFactor ^ floor((epoch-1)/lrDropPeriod));

    for batch = 1:numBatches
        iteration = iteration + 1;

        % Get mini-batch
        batchIdx = (batch-1)*miniBatchSize+1 : batch*miniBatchSize;
        XBatch   = dlarray(single(XTrainShuffled(:, batchIdx)), "CB");
        YBatch   = dlarray(single(YTrainShuffled(:, batchIdx)), "CB");

        % Compute gradients using automatic differentiation
        [loss, gradsAttn, gradsMain] = dlfeval(@forwardPass, ...
            attentionLayers, mainLayers, XBatch, YBatch);

        % Update attention network weights
        [attentionLayers, trailingAvgAttn, trailingAvgSqAttn] = ...
            adamupdate(attentionLayers, gradsAttn, ...
            trailingAvgAttn, trailingAvgSqAttn, iteration, ...
            currentLR, gradDecay, sqGradDecay);

        % Update main network weights
        [mainLayers, trailingAvgMain, trailingAvgSqMain] = ...
            adamupdate(mainLayers, gradsMain, ...
            trailingAvgMain, trailingAvgSqMain, iteration, ...
            currentLR, gradDecay, sqGradDecay);
    end

    % Validation loss every 500 iterations
    if mod(iteration, 500) == 0 || epoch == maxEpochs
        XVal  = dlarray(single(rsrpValInput), "CB");
        YVal  = dlarray(single(rsrpValVec),   "CB");
        [valLoss, ~, ~] = dlfeval(@forwardPass, ...
            attentionLayers, mainLayers, XVal, YVal);
        valLossVal = double(extractdata(valLoss));

        % Save best model
        if valLossVal < bestValLoss
            bestValLoss      = valLossVal;
            bestAttnNet      = attentionLayers;
            bestMainNet      = mainLayers;
        end

        fprintf("%-10d %-8d %-15.5f %-15.5f\n", ...
            iteration, epoch, double(extractdata(loss)), valLossVal)
    end
end

trainingTime = toc;
fprintf("Training finished in %.1f seconds.\n", trainingTime)
fprintf("Best validation loss: %.5f\n", bestValLoss)

% Use best model for evaluation
attentionLayers = bestAttnNet;
mainLayers      = bestMainNet;

% Save trained models
save("method1_attentionNN.mat", "attentionLayers", "mainLayers", "bestValLoss")
disp("Attention NN model saved.")

%% ── 6. EVALUATE: TOP-K ACCURACY ─────────────────────────────────────────
rng(111)
statisticCount = accumarray(optBeamPairIdxScalarTrain, 1, [numBeamPairs, 1]);

% Get predictions for all test samples
XTest = dlarray(single(rsrpTestInput), "CB");
attnWeights  = predict(attentionLayers, XTest, InputDataFormats="CB");
weightedTest = attnWeights .* XTest;
predAttnOutput = predict(mainLayers, weightedTest, InputDataFormats="CB");
predAttnOutput = extractdata(predAttnOutput);

K            = numBeamPairs;
accAttn      = zeros(1,K);
accRandom    = zeros(1,K);

for k = 1:K
    predCorrectAttn   = zeros(testDataLen,1);
    predCorrectRandom = zeros(testDataLen,1);

    for n = 1:testDataLen
        [~, trueOptBeamIdx] = max(rsrpMatTest(:,:,n), [], "all", "linear");

        % Attention NN
        [~, topK] = maxk(predAttnOutput(:,n), k);
        predCorrectAttn(n) = any(topK == trueOptBeamIdx);

        % Random
        topK = randperm(numBeamPairs, k);
        predCorrectRandom(n) = any(topK == trueOptBeamIdx);
    end

    accuracy       = @(x) nnz(x)/testDataLen*100;
    accAttn(k)     = accuracy(predCorrectAttn);
    accRandom(k)   = accuracy(predCorrectRandom);
end

fprintf("\n=== Attention NN Top-K Accuracy Results ===\n")
fprintf("Top-1  Accuracy: %.4f%%\n", accAttn(1))
fprintf("Top-3  Accuracy: %.4f%%\n", accAttn(3))
fprintf("Top-5  Accuracy: %.4f%%\n", accAttn(5))
fprintf("Top-10 Accuracy: %.4f%%\n", accAttn(10))
fprintf("Top-18 Accuracy: %.4f%%\n", accAttn(18))

%% ── 7. EVALUATE: AVERAGE RSRP ───────────────────────────────────────────
rng(111)
rsrpAttn    = zeros(1,K);
rsrpOptimal = zeros(1,K);

for k = 1:K
    rsrpSumAttn = 0;
    rsrpSumOpt  = 0;

    for n = 1:testDataLen
        rsrp = rsrpMatTest(:,:,n);
        [~, trueOptBeamIdx] = max(rsrpTestVec(:,n));
        rsrpSumOpt  = rsrpSumOpt  + rsrp(trueOptBeamIdx);

        [~, topK] = maxk(predAttnOutput(:,n), k);
        rsrpSumAttn = rsrpSumAttn + max(rsrp(topK));
    end

    rsrpAttn(k)    = rsrpSumAttn / testDataLen;
    rsrpOptimal(k) = rsrpSumOpt  / testDataLen;
end

fprintf("\n=== Attention NN Average RSRP Results ===\n")
fprintf("Avg RSRP Attn    K=1:  %.4f dBm\n", rsrpAttn(1))
fprintf("Avg RSRP Attn    K=5:  %.4f dBm\n", rsrpAttn(5))
fprintf("Avg RSRP Attn    K=10: %.4f dBm\n", rsrpAttn(10))
fprintf("Avg RSRP Optimal K=1:  %.4f dBm\n", rsrpOptimal(1))

%% ── 8. COMPARISON PLOTS ─────────────────────────────────────────────────
if exist("accNeural","var") && exist("rsrpNeural","var")

    % Top-K Accuracy
    figure
    plot(1:K, accAttn,   "--b*", LineWidth=1.5); hold on
    plot(1:K, accNeural, "--ro", LineWidth=1.5)
    grid on
    xticks([1 3 5 10 15:5:K])
    xlabel("$K$", Interpreter="latex")
    ylabel("Top-$K$ Accuracy (\%)", Interpreter="latex")
    title("Attention NN vs Baseline NN — Top-K Accuracy")
    legend("Attention NN (Proposed)","Baseline NN", Location="best")
    saveas(gcf, "method1_topK_accuracy.png")

    % Average RSRP
    figure
    plot(1:K, rsrpAttn,   "--b*", LineWidth=1.5); hold on
    plot(1:K, rsrpNeural, "--ro", LineWidth=1.5)
    plot(1:K, rsrpOptimal,"--g*", LineWidth=1.5)
    grid on
    xticks([1 3 5 10 15:5:K])
    xlabel("$K$", Interpreter="latex")
    ylabel("Average RSRP (dBm)")
    title("Attention NN vs Baseline NN — Average RSRP")
    legend("Attention NN (Proposed)","Baseline NN","Exhaustive Search", Location="best")
    saveas(gcf, "method1_avg_rsrp.png")

    % Print improvement summary
    fprintf("\n=== Improvement over Baseline ===\n")
    fprintf("Top-1  : %+.4f%%\n", accAttn(1)  - accNeural(1))
    fprintf("Top-3  : %+.4f%%\n", accAttn(3)  - accNeural(3))
    fprintf("Top-5  : %+.4f%%\n", accAttn(5)  - accNeural(5))
    fprintf("Top-10 : %+.4f%%\n", accAttn(10) - accNeural(10))
    fprintf("Top-18 : %+.4f%%\n", accAttn(18) - accNeural(18))
    fprintf("RSRP K=1  : %+.4f dBm\n", rsrpAttn(1)  - rsrpNeural(1))
    fprintf("RSRP K=5  : %+.4f dBm\n", rsrpAttn(5)  - rsrpNeural(5))
    fprintf("RSRP K=10 : %+.4f dBm\n", rsrpAttn(10) - rsrpNeural(10))

    disp("Method 1 comparison plots saved.")
else
    disp("Note: run NeuralNetworkBeamSelectionExample.m first for comparison plots.")
end

%% ════════════════════════════════════════════════════════════════════════
%  LOCAL FUNCTIONS
%% ════════════════════════════════════════════════════════════════════════

function [loss, gradsAttn, gradsMain] = forwardPass(attnNet, mainNet, X, Y)
    % Forward pass through attention + main network
    % X: 14 x miniBatchSize dlarray
    % Y: 70 x miniBatchSize dlarray (target RSRP vectors)

    % Step 1: Attention network produces 14 weights summing to 1
    attnWeights = forward(attnNet, X);

    % Step 2: Element-wise multiply weights with inputs
    weightedX = attnWeights .* X;

    % Step 3: Main network produces 70 RSRP predictions
    YPred = forward(mainNet, weightedX);

    % Step 4: MSE loss (same as baseline)
    loss = mse(YPred, Y);

    % Step 5: Compute gradients for both networks
    gradsAttn = dlgradient(loss, attnNet.Learnables);
    gradsMain = dlgradient(loss, mainNet.Learnables);
end

function optBeamPairIdxScalar = processData(prm, rsrpMat)
    numBeamPairs = prm.NumRxBeams * prm.NumTxBeams;
    rsrpReshaped = reshape(rsrpMat, numBeamPairs, []);
    [~, optBeamPairIdxScalar] = max(rsrpReshaped, [], 1);
    optBeamPairIdxScalar = optBeamPairIdxScalar(:);
end
