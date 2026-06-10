%% Method 2: Dual-Output Neural Network for Beam Selection
% Novel contribution: a single network trained simultaneously with two heads:
%   Head 1 - Regression: predicts full 70-element RSRP vector (like baseline)
%   Head 2 - Classification: directly predicts best beam index (softmax)
%
% Combined loss = alpha * MSE_loss + (1-alpha) * CrossEntropy_loss
%
% Why this is better than baseline:
%   Baseline only uses MSE which is misaligned with Top-K accuracy.
%   Adding cross-entropy directly optimizes for correct beam prediction.
%
% Architecture:
%   14 RSRP inputs
%   - Shared layers: FC(64)-ReLU -> FC(128)-ReLU -> FC(256)-ReLU
%   - Head 1: FC(128)-ReLU -> FC(70)-tanh    [regression output]
%   - Head 2: FC(128)-ReLU -> FC(70)-softmax  [classification output]

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

% Get optimal beam indices for classification head training
optBeamTrain = optBeamPairIdxScalarTrain(shuffledIdx);
optBeamTrain = optBeamTrain(valDataLen+1:end);   % training labels
optBeamVal   = optBeamPairIdxScalarTrain(shuffledIdx);
optBeamVal   = optBeamVal(1:valDataLen);          % validation labels

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

% Convert beam labels to one-hot for cross-entropy
numTrain = size(rsrpTrainInput, 2);
numVal   = size(rsrpValInput,   2);

oneHotTrain = zeros(numBeamPairs, numTrain, "single");
for i = 1:numTrain
    oneHotTrain(optBeamTrain(i), i) = 1;
end

oneHotVal = zeros(numBeamPairs, numVal, "single");
for i = 1:numVal
    oneHotVal(optBeamVal(i), i) = 1;
end

%% ── 4. BUILD DUAL-OUTPUT NETWORK ─────────────────────────────────────────
% Using layerGraph to create branching architecture

lgraph = layerGraph();

% --- Input ---
lgraph = addLayers(lgraph, featureInputLayer(numSampledBeams, Name="input"));

% --- Shared layers ---
lgraph = addLayers(lgraph, [
    fullyConnectedLayer(64,  Name="shared_fc1")
    reluLayer(Name="shared_relu1")
    fullyConnectedLayer(128, Name="shared_fc2")
    reluLayer(Name="shared_relu2")
    fullyConnectedLayer(256, Name="shared_fc3")
    reluLayer(Name="shared_relu3")]);

% --- Regression head (like baseline) ---
lgraph = addLayers(lgraph, [
    fullyConnectedLayer(128, Name="reg_fc1")
    reluLayer(Name="reg_relu1")
    fullyConnectedLayer(numBeamPairs, Name="reg_out")
    tanhLayer(Name="reg_tanh")]);

% --- Classification head (novel) ---
lgraph = addLayers(lgraph, [
    fullyConnectedLayer(128, Name="cls_fc1")
    reluLayer(Name="cls_relu1")
    fullyConnectedLayer(numBeamPairs, Name="cls_out")
    softmaxLayer(Name="cls_softmax")]);

% --- Connect layers ---
lgraph = connectLayers(lgraph, "input",        "shared_fc1");
lgraph = connectLayers(lgraph, "shared_relu3", "reg_fc1");
lgraph = connectLayers(lgraph, "shared_relu3", "cls_fc1");

% Convert to dlnetwork
dualNet = dlnetwork(lgraph);
disp("Dual-Output NN architecture built successfully.")

%% ── 5. CUSTOM TRAINING LOOP ──────────────────────────────────────────────
% alpha controls the balance between regression and classification loss
% alpha = 0.5 means equal weight to both losses
alpha = 0.5;

maxEpochs     = 500;
miniBatchSize = 200;
learnRate     = 1e-4;
lrDropPeriod  = 10;
lrDropFactor  = 0.8;

numTrainSamples = size(rsrpTrainInput, 2);
numBatches      = floor(numTrainSamples / miniBatchSize);

trailingAvg   = [];
trailingAvgSq = [];
gradDecay     = 0.9;
sqGradDecay   = 0.999;

bestValLoss = inf;
iteration   = 0;

fprintf("\nStarting Dual-Output NN training...\n")
fprintf("%-10s %-8s %-15s %-15s\n","Iteration","Epoch","TrainingLoss","ValidationLoss")
tic

for epoch = 1:maxEpochs

    % Shuffle training data
    shuffleIdx       = randperm(numTrainSamples);
    XTrainShuffled   = rsrpTrainInput(:, shuffleIdx);
    YRegShuffled     = rsrpTrainVec(:,   shuffleIdx);
    YClsShuffled     = oneHotTrain(:,    shuffleIdx);

    currentLR = learnRate * (lrDropFactor ^ floor((epoch-1)/lrDropPeriod));

    for batch = 1:numBatches
        iteration = iteration + 1;

        batchIdx = (batch-1)*miniBatchSize+1 : batch*miniBatchSize;
        XBatch   = dlarray(single(XTrainShuffled(:, batchIdx)), "CB");
        YRegBatch= dlarray(single(YRegShuffled(:,   batchIdx)), "CB");
        YClsBatch= dlarray(single(YClsShuffled(:,   batchIdx)), "CB");

        % Compute loss and gradients
        [loss, grads] = dlfeval(@dualForwardPass, dualNet, ...
            XBatch, YRegBatch, YClsBatch, alpha);

        % Update network
        [dualNet, trailingAvg, trailingAvgSq] = adamupdate(dualNet, grads, ...
            trailingAvg, trailingAvgSq, iteration, currentLR, ...
            gradDecay, sqGradDecay);
    end

    % Validation every 500 iterations
    if mod(iteration, 500) == 0 || epoch == maxEpochs
        XVal     = dlarray(single(rsrpValInput), "CB");
        YRegVal  = dlarray(single(rsrpValVec),   "CB");
        YClsVal  = dlarray(single(oneHotVal),    "CB");

        [valLoss, ~] = dlfeval(@dualForwardPass, dualNet, ...
            XVal, YRegVal, YClsVal, alpha);
        valLossVal = double(extractdata(valLoss));

        if valLossVal < bestValLoss
            bestValLoss = valLossVal;
            bestDualNet = dualNet;
        end

        fprintf("%-10d %-8d %-15.5f %-15.5f\n", ...
            iteration, epoch, double(extractdata(loss)), valLossVal)
    end
end

trainingTime = toc;
fprintf("Training finished in %.1f seconds.\n", trainingTime)
fprintf("Best validation loss: %.5f\n", bestValLoss)

dualNet = bestDualNet;
save("method2_dualOutputNN.mat", "dualNet", "bestValLoss")
disp("Dual-Output NN model saved.")

%% ── 6. EVALUATE: TOP-K ACCURACY ─────────────────────────────────────────
% For evaluation we use the REGRESSION head output (70 RSRP predictions)
% and also test using CLASSIFICATION head output (70 beam probabilities)
% We report whichever performs better

rng(111)
statisticCount = accumarray(optBeamPairIdxScalarTrain, 1, [numBeamPairs, 1]);

XTest = dlarray(single(rsrpTestInput), "CB");
[predReg, predCls] = forward(dualNet, XTest);
predReg = extractdata(predReg);   % 70 x testDataLen (RSRP predictions)
predCls = extractdata(predCls);   % 70 x testDataLen (beam probabilities)

K          = numBeamPairs;
accReg     = zeros(1,K);
accCls     = zeros(1,K);
accRandom  = zeros(1,K);

for k = 1:K
    predCorrectReg    = zeros(testDataLen,1);
    predCorrectCls    = zeros(testDataLen,1);
    predCorrectRandom = zeros(testDataLen,1);

    for n = 1:testDataLen
        [~, trueOptBeamIdx] = max(rsrpMatTest(:,:,n), [], "all", "linear");

        % Regression head
        [~, topK] = maxk(predReg(:,n), k);
        predCorrectReg(n) = any(topK == trueOptBeamIdx);

        % Classification head
        [~, topK] = maxk(predCls(:,n), k);
        predCorrectCls(n) = any(topK == trueOptBeamIdx);

        % Random
        topK = randperm(numBeamPairs, k);
        predCorrectRandom(n) = any(topK == trueOptBeamIdx);
    end

    accuracy        = @(x) nnz(x)/testDataLen*100;
    accReg(k)       = accuracy(predCorrectReg);
    accCls(k)       = accuracy(predCorrectCls);
    accRandom(k)    = accuracy(predCorrectRandom);
end

fprintf("\n=== Dual-Output NN Top-K Accuracy Results ===\n")
fprintf("%-6s %-20s %-20s\n","K","Regression Head","Classification Head")
for k = [1 3 5 10 18]
    fprintf("%-6d %-20.4f %-20.4f\n", k, accReg(k), accCls(k))
end

%% ── 7. EVALUATE: AVERAGE RSRP ───────────────────────────────────────────
rng(111)
rsrpReg     = zeros(1,K);
rsrpCls     = zeros(1,K);
rsrpOptimal = zeros(1,K);

for k = 1:K
    rsrpSumReg = 0; rsrpSumCls = 0; rsrpSumOpt = 0;

    for n = 1:testDataLen
        rsrp = rsrpMatTest(:,:,n);
        [~, trueOptBeamIdx] = max(rsrpTestVec(:,n));
        rsrpSumOpt = rsrpSumOpt + rsrp(trueOptBeamIdx);

        [~, topK] = maxk(predReg(:,n), k);
        rsrpSumReg = rsrpSumReg + max(rsrp(topK));

        [~, topK] = maxk(predCls(:,n), k);
        rsrpSumCls = rsrpSumCls + max(rsrp(topK));
    end

    rsrpReg(k)     = rsrpSumReg / testDataLen;
    rsrpCls(k)     = rsrpSumCls / testDataLen;
    rsrpOptimal(k) = rsrpSumOpt / testDataLen;
end

fprintf("\n=== Dual-Output NN Average RSRP Results ===\n")
fprintf("Avg RSRP Regression K=1:  %.4f dBm\n", rsrpReg(1))
fprintf("Avg RSRP Classif.   K=1:  %.4f dBm\n", rsrpCls(1))
fprintf("Avg RSRP Regression K=10: %.4f dBm\n", rsrpReg(10))
fprintf("Avg RSRP Classif.   K=10: %.4f dBm\n", rsrpCls(10))
fprintf("Avg RSRP Optimal    K=1:  %.4f dBm\n", rsrpOptimal(1))

%% ── 8. COMPARISON PLOTS ─────────────────────────────────────────────────
if exist("accNeural","var") && exist("rsrpNeural","var")

    % Use classification head for comparison (directly optimized for beam)
    figure
    plot(1:K, accCls,    "--b*", LineWidth=1.5); hold on
    plot(1:K, accReg,    "--ms", LineWidth=1.5)
    plot(1:K, accNeural, "--ro", LineWidth=1.5)
    grid on
    xticks([1 3 5 10 15:5:K])
    xlabel("$K$", Interpreter="latex")
    ylabel("Top-$K$ Accuracy (\%)", Interpreter="latex")
    title("Dual-Output NN vs Baseline NN — Top-K Accuracy")
    legend("Dual-Output (Cls Head)","Dual-Output (Reg Head)","Baseline NN", Location="best")
    saveas(gcf, "method2_topK_accuracy.png")

    figure
    plot(1:K, rsrpCls,    "--b*", LineWidth=1.5); hold on
    plot(1:K, rsrpReg,    "--ms", LineWidth=1.5)
    plot(1:K, rsrpNeural, "--ro", LineWidth=1.5)
    plot(1:K, rsrpOptimal,"--g*", LineWidth=1.5)
    grid on
    xticks([1 3 5 10 15:5:K])
    xlabel("$K$", Interpreter="latex")
    ylabel("Average RSRP (dBm)")
    title("Dual-Output NN vs Baseline NN — Average RSRP")
    legend("Dual-Output (Cls)","Dual-Output (Reg)","Baseline NN","Exhaustive Search", Location="best")
    saveas(gcf, "method2_avg_rsrp.png")

    fprintf("\n=== Improvement over Baseline (Classification Head) ===\n")
    fprintf("Top-1  : %+.4f%%\n", accCls(1)  - accNeural(1))
    fprintf("Top-3  : %+.4f%%\n", accCls(3)  - accNeural(3))
    fprintf("Top-5  : %+.4f%%\n", accCls(5)  - accNeural(5))
    fprintf("Top-10 : %+.4f%%\n", accCls(10) - accNeural(10))
    fprintf("Top-18 : %+.4f%%\n", accCls(18) - accNeural(18))

    disp("Method 2 comparison plots saved.")
else
    disp("Note: run NeuralNetworkBeamSelectionExample.m first for comparison.")
end

%% ════════════════════════════════════════════════════════════════════════
%  LOCAL FUNCTIONS
%% ════════════════════════════════════════════════════════════════════════

function [loss, grads] = dualForwardPass(net, X, YReg, YCls, alpha)
    % Forward pass through dual-output network
    % Computes combined loss from both heads

    % Forward pass — gets outputs from both heads
    [predReg, predCls] = forward(net, X);

    % Head 1: MSE regression loss (same as baseline)
    regLoss = mse(predReg, YReg);

    % Head 2: Cross-entropy classification loss
    % Clip predictions to avoid log(0)
    predClsSafe = max(predCls, dlarray(1e-7));
    clsLoss = mean(sum(-YCls .* log(predClsSafe), 1));

    % Combined loss
    loss = alpha * regLoss + (1 - alpha) * clsLoss;

    % Gradients
    grads = dlgradient(loss, net.Learnables);
end

function optBeamPairIdxScalar = processData(prm, rsrpMat)
    numBeamPairs = prm.NumRxBeams * prm.NumTxBeams;
    rsrpReshaped = reshape(rsrpMat, numBeamPairs, []);
    [~, optBeamPairIdxScalar] = max(rsrpReshaped, [], 1);
    optBeamPairIdxScalar = optBeamPairIdxScalar(:);
end
