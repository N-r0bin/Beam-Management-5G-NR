%% Method 3: Ensemble: Random Forest + Classification NN
% Novel contribution: combines two fundamentally different ML models:
%   Model 1: Classification NN (from Method 2's classification head)
%   Model 2: Random Forest Classifier
%
% Both models predict beam probabilities independently.
% Final prediction = soft voting: average of both models' probabilities.
%
% Why this works better:
%   - NN learns complex non-linear patterns
%   - Random Forest learns decision boundaries robustly
%   - Ensemble reduces individual model errors through complementary strengths
%
% Supported by: Chatzoglou & Goudos (Sensors, 2023) - ensemble learning
% outperforms individual models for 5G beam selection.

%% ─ 1. LOAD DATA (identical to baseline) ────────────────────────────────
filenameParam     = "nnBS_prm.mat";
filenameTrainData = "nnBS_TrainingData.mat";
filenameTestData  = "nnBS_TestData.mat";

load(filenameParam);
load(filenameTrainData);
load(filenameTestData);

%% ─ 2. PROCESS DATA (identical to baseline) ─────────────────────────────
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

% Beam labels for classification
optBeamTrain = optBeamPairIdxScalarTrain(shuffledIdx);
optBeamTrainLabels = optBeamTrain(valDataLen+1:end);  % for RF training

%% ─ 3. NORMALISE → RESHAPE → DOWNSAMPLE (identical to baseline) ─────────
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

%% ─ 4. TRAIN RANDOM FOREST CLASSIFIER ───────────────────────────────────
% Random Forest treats beam selection as multi-class classification
% Input:  14 RSRP values
% Output: predicted best beam index (1 to 70)
% Uses 200 trees for robust voting

disp("Training Random Forest classifier...")
tic

% Prepare training data for RF (samples x features format)
XTrainRF = rsrpTrainInput';                          % N x 14
YTrainRF = categorical(optBeamTrainLabels);          % N x 1 (beam labels)

% Train Random Forest with 200 decision trees
rfModel = TreeBagger(200, XTrainRF, YTrainRF, ...
    Method="classification", ...
    OOBPrediction="on", ...
    MinLeafSize=5, ...
    NumPredictorsToSample="all");

rfTime = toc;
fprintf("Random Forest trained in %.1f seconds.\n", rfTime)

% Get RF out-of-bag error to check quality
oobErr = oobError(rfModel);
fprintf("RF Out-of-Bag Classification Error: %.4f\n", oobErr(end))

% Save RF model
save("method3_rfModel.mat", "rfModel")
disp("Random Forest model saved.")

%% ─ 5. LOAD OR TRAIN CLASSIFICATION NN ───────────────────────────────────
% Load Method 2's dual-output network if available
% Otherwise train a fresh classification NN

if isfile("method2_dualOutputNN.mat")
    disp("Loading Classification NN from Method 2...")
    load("method2_dualOutputNN.mat", "dualNet")
    clsNet = dualNet;
    disp("Classification NN loaded.")
else
    disp("Method 2 model not found. Training fresh Classification NN...")
    % Train a simple classification NN
    % (same as Method 2 classification head but standalone)

    optBeamVal   = optBeamPairIdxScalarTrain(shuffledIdx);
    optBeamVal   = optBeamVal(1:valDataLen);

    numTrain = size(rsrpTrainInput, 2);
    numVal   = size(rsrpValInput,   2);

    oneHotTrain = zeros(numBeamPairs, numTrain, "single");
    for i = 1:numTrain
        oneHotTrain(optBeamTrainLabels(i), i) = 1;
    end
    oneHotVal = zeros(numBeamPairs, numVal, "single");
    for i = 1:numVal
        oneHotVal(optBeamVal(i), i) = 1;
    end

    clsNet = dlnetwork([...
        featureInputLayer(numSampledBeams, Name="input")
        fullyConnectedLayer(64,  Name="fc1"); reluLayer(Name="relu1")
        fullyConnectedLayer(128, Name="fc2"); reluLayer(Name="relu2")
        fullyConnectedLayer(256, Name="fc3"); reluLayer(Name="relu3")
        fullyConnectedLayer(128, Name="fc4"); reluLayer(Name="relu4")
        fullyConnectedLayer(numBeamPairs, Name="fc_out")
        softmaxLayer(Name="softmax")]);

    maxEpochs     = 300;
    miniBatchSize = 200;
    learnRate     = 1e-4;
    numBatches    = floor(numTrain / miniBatchSize);
    trailingAvg = []; trailingAvgSq = [];
    iteration = 0; bestValLoss = inf;

    for epoch = 1:maxEpochs
        shuffIdx = randperm(numTrain);
        XS = rsrpTrainInput(:, shuffIdx);
        YS = oneHotTrain(:, shuffIdx);
        currentLR = learnRate * (0.8^floor((epoch-1)/10));

        for batch = 1:numBatches
            iteration = iteration + 1;
            bIdx = (batch-1)*miniBatchSize+1:batch*miniBatchSize;
            XB = dlarray(single(XS(:,bIdx)), "CB");
            YB = dlarray(single(YS(:,bIdx)), "CB");

            [lossVal, grads] = dlfeval(@clsForwardPass, clsNet, XB, YB);
            [clsNet, trailingAvg, trailingAvgSq] = adamupdate(clsNet, grads, ...
                trailingAvg, trailingAvgSq, iteration, currentLR);
        end

        if mod(iteration,500)==0
            XV = dlarray(single(rsrpValInput), "CB");
            YV = dlarray(single(oneHotVal), "CB");
            [vl,~] = dlfeval(@clsForwardPass, clsNet, XV, YV);
            vld = double(extractdata(vl));
            if vld < bestValLoss
                bestValLoss = vld;
                bestClsNet = clsNet;
            end
        end
    end
    clsNet = bestClsNet;
    save("method3_clsNet.mat", "clsNet")
    disp("Classification NN trained and saved.")
end

%% ─ 6. GET PREDICTIONS FROM BOTH MODELS ─────────────────────────────────
disp("Getting predictions from both models...")

% --- Classification NN predictions ---
XTest = dlarray(single(rsrpTestInput), "CB");

% Get classification head output from dual network
[~, predCLS] = forward(clsNet, XTest);
predCLS = extractdata(predCLS);    % 70 x testDataLen (probabilities)

% --- Random Forest predictions ---
XTestRF = rsrpTestInput';          % testDataLen x 14
[~, rfScores] = predict(rfModel, XTestRF);
% rfScores: testDataLen x 70 (probability per class per sample)
rfProbs = rfScores';               % 70 x testDataLen

% --- Ensemble: soft voting (average probabilities) ---
% Normalize NN output to [0,1] range for fair combination
predCLSnorm = (predCLS - min(predCLS,[],1)) ./ ...
    (max(predCLS,[],1) - min(predCLS,[],1) + eps);

ensembleProbs = 0.5 * predCLSnorm + 0.5 * rfProbs;   % equal weight

disp("Ensemble predictions computed.")

%% ─ 7. EVALUATE: TOP-K ACCURACY ─────────────────────────────────────────
rng(111)
K          = numBeamPairs;
accEns     = zeros(1,K);
accNN      = zeros(1,K);
accRF      = zeros(1,K);
accRandom  = zeros(1,K);

for k = 1:K
    predCorrectEns    = zeros(testDataLen,1);
    predCorrectNN     = zeros(testDataLen,1);
    predCorrectRF     = zeros(testDataLen,1);
    predCorrectRandom = zeros(testDataLen,1);

    for n = 1:testDataLen
        [~, trueOptBeamIdx] = max(rsrpMatTest(:,:,n), [], "all", "linear");

        % Ensemble
        [~, topK] = maxk(ensembleProbs(:,n), k);
        predCorrectEns(n) = any(topK == trueOptBeamIdx);

        % NN alone
        [~, topK] = maxk(predCLSnorm(:,n), k);
        predCorrectNN(n) = any(topK == trueOptBeamIdx);

        % RF alone
        [~, topK] = maxk(rfProbs(:,n), k);
        predCorrectRF(n) = any(topK == trueOptBeamIdx);

        % Random
        topK = randperm(numBeamPairs, k);
        predCorrectRandom(n) = any(topK == trueOptBeamIdx);
    end

    accuracy       = @(x) nnz(x)/testDataLen*100;
    accEns(k)      = accuracy(predCorrectEns);
    accNN(k)       = accuracy(predCorrectNN);
    accRF(k)       = accuracy(predCorrectRF);
    accRandom(k)   = accuracy(predCorrectRandom);
end

fprintf("\n=== Method 3 Top-K Accuracy Results ===\n")
fprintf("%-6s %-15s %-15s %-15s %-15s\n", ...
    "K","Ensemble","Cls NN","Random Forest","Baseline NN")
for k = [1 3 5 10 18]
    fprintf("%-6d %-15.4f %-15.4f %-15.4f %-15.4f\n", ...
        k, accEns(k), accNN(k), accRF(k), accNeural(k))
end

%% ─ 8. EVALUATE: AVERAGE RSRP ───────────────────────────────────────────
rng(111)
rsrpEns     = zeros(1,K);
rsrpRF      = zeros(1,K);
rsrpOptimal = zeros(1,K);

for k = 1:K
    rsrpSumEns = 0; rsrpSumRF = 0; rsrpSumOpt = 0;

    for n = 1:testDataLen
        rsrp = rsrpMatTest(:,:,n);
        [~, trueOptBeamIdx] = max(rsrpTestVec(:,n));
        rsrpSumOpt = rsrpSumOpt + rsrp(trueOptBeamIdx);

        [~, topK] = maxk(ensembleProbs(:,n), k);
        rsrpSumEns = rsrpSumEns + max(rsrp(topK));

        [~, topK] = maxk(rfProbs(:,n), k);
        rsrpSumRF = rsrpSumRF + max(rsrp(topK));
    end

    rsrpEns(k)     = rsrpSumEns / testDataLen;
    rsrpRF(k)      = rsrpSumRF  / testDataLen;
    rsrpOptimal(k) = rsrpSumOpt / testDataLen;
end

fprintf("\n=== Method 3 Average RSRP Results ===\n")
fprintf("Avg RSRP Ensemble K=1:  %.4f dBm\n", rsrpEns(1))
fprintf("Avg RSRP Ensemble K=5:  %.4f dBm\n", rsrpEns(5))
fprintf("Avg RSRP Ensemble K=10: %.4f dBm\n", rsrpEns(10))
fprintf("Avg RSRP RF only  K=1:  %.4f dBm\n", rsrpRF(1))
fprintf("Avg RSRP Optimal  K=1:  %.4f dBm\n", rsrpOptimal(1))

%% ─ 9. COMPARISON PLOTS ─────────────────────────────────────────────────
if exist("accNeural","var") && exist("rsrpNeural","var")

    % Top-K Accuracy — all methods
    figure
    plot(1:K, accEns,    "--b*",  LineWidth=1.5); hold on
    plot(1:K, accNN,     "--ms",  LineWidth=1.5)
    plot(1:K, accRF,     "--kd",  LineWidth=1.5)
    plot(1:K, accNeural, "--ro",  LineWidth=1.5)
    grid on
    xticks([1 3 5 10 15:5:K])
    xlabel("$K$", Interpreter="latex")
    ylabel("Top-$K$ Accuracy (\%)", Interpreter="latex")
    title("Method 3: Ensemble vs Individual Models — Top-K Accuracy")
    legend("Ensemble (RF+NN)","Cls NN alone","RF alone","Baseline NN", Location="best")
    saveas(gcf, "method3_topK_accuracy.png")

    % Average RSRP
    figure
    plot(1:K, rsrpEns,    "--b*", LineWidth=1.5); hold on
    plot(1:K, rsrpRF,     "--kd", LineWidth=1.5)
    plot(1:K, rsrpNeural, "--ro", LineWidth=1.5)
    plot(1:K, rsrpOptimal,"--g*", LineWidth=1.5)
    grid on
    xticks([1 3 5 10 15:5:K])
    xlabel("$K$", Interpreter="latex")
    ylabel("Average RSRP (dBm)")
    title("Method 3: Ensemble vs Baseline — Average RSRP")
    legend("Ensemble (RF+NN)","RF alone","Baseline NN","Exhaustive Search", Location="best")
    saveas(gcf, "method3_avg_rsrp.png")

    fprintf("\n=== Ensemble Improvement over Baseline ===\n")
    fprintf("Top-1  : %+.4f%%\n", accEns(1)  - accNeural(1))
    fprintf("Top-3  : %+.4f%%\n", accEns(3)  - accNeural(3))
    fprintf("Top-5  : %+.4f%%\n", accEns(5)  - accNeural(5))
    fprintf("Top-10 : %+.4f%%\n", accEns(10) - accNeural(10))
    fprintf("Top-18 : %+.4f%%\n", accEns(18) - accNeural(18))
    fprintf("RSRP K=1  : %+.4f dBm\n", rsrpEns(1)  - rsrpNeural(1))
    fprintf("RSRP K=5  : %+.4f dBm\n", rsrpEns(5)  - rsrpNeural(5))
    fprintf("RSRP K=10 : %+.4f dBm\n", rsrpEns(10) - rsrpNeural(10))

    disp("Method 3 comparison plots saved.")
else
    disp("Note: run NeuralNetworkBeamSelectionExample.m first for comparison.")
end

%% ════════════════════════════════════════════════════════════════════════
%  LOCAL FUNCTIONS
%% ════════════════════════════════════════════════════════════════════════

function [loss, grads] = clsForwardPass(net, X, Y)
    pred = forward(net, X);
    predSafe = max(pred, dlarray(1e-7));
    loss = mean(sum(-Y .* log(predSafe), 1));
    grads = dlgradient(loss, net.Learnables);
end

function optBeamPairIdxScalar = processData(prm, rsrpMat)
    numBeamPairs = prm.NumRxBeams * prm.NumTxBeams;
    rsrpReshaped = reshape(rsrpMat, numBeamPairs, []);
    [~, optBeamPairIdxScalar] = max(rsrpReshaped, [], 1);
    optBeamPairIdxScalar = optBeamPairIdxScalar(:);
end
