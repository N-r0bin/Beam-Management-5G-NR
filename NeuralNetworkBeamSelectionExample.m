%% Neural Network for Beam Selection — Main Script
% Clean code-only version extracted from MathWorks example
% Reference: https://www.mathworks.com/help/comm/ug/neural-network-for-beam-selection.html

%% ── 1. LOAD / GENERATE DATA ──────────────────────────────────────────────
useSavedData      = true;   % true  → use the .mat files you downloaded
saveData          = false;  % false → don't overwrite saved data
filenameParam     = "nnBS_prm.mat";
filenameTrainData = "nnBS_TrainingData.mat";
filenameTestData  = "nnBS_TestData.mat";

if useSavedData
    load(filenameParam);      % loads: prm
    load(filenameTrainData);  % loads: optBeamPairIdxTrain, rsrpMatTrain, dataTrain
    load(filenameTestData);   % loads: optBeamPairIdxTest,  rsrpMatTest,  dataTest
end

%% ── 2. DEFINE DATA-GENERATION PARAMETERS (skipped when useSavedData=true) ─
if ~useSavedData
    prm.NCellID           = 1;
    prm.FrequencyRange    = "FR2";
    prm.Scenario          = "UMa";
    prm.CenterFrequency   = 30e9;        % Hz
    prm.SSBlockPattern    = "Case D";
    prm.NumSSBlocks       = [];
    prm.InterSiteDistance = 200;         % metres
    prm.PowerBSs          = 40;          % dBm
    prm.UENoiseFigure     = 10;          % dB
    prm.RSRPMode          = "SSSwDMRS";

    c          = physconst("LightSpeed");
    prm.Lambda = c / prm.CenterFrequency;
    prm.ElevationSweep = false;

    prm.TransmitAntennaArray = phased.NRRectangularPanelArray( ...
        Size=[4,8,1,1], Spacing=[0.5,0.5,1,1]*prm.Lambda);
    prm.TxAZlim    = [-60  60];
    prm.TxELlim    = [-90   0];
    prm.TxDowntilt = 110;

    prm.ReceiveAntennaArray = phased.NRRectangularPanelArray( ...
        Size=[1,4,1,1], Spacing=[0.5,0.5,1,1]*prm.Lambda, ...
        ElementSet={phased.ShortDipoleAntennaElement, ...
                    phased.ShortDipoleAntennaElement});
    prm.ReceiveAntennaArray.ElementSet{1}.AxisDirection       = "Custom";
    prm.ReceiveAntennaArray.ElementSet{1}.CustomAxisDirection = [0;  1; 1];
    prm.ReceiveAntennaArray.ElementSet{2}.AxisDirection       = "Custom";
    prm.ReceiveAntennaArray.ElementSet{2}.CustomAxisDirection = [0; -1; 1];
    prm.RxAZlim = [-90 90];
    prm.RxELlim = [  0 90];

    prm = validateParams(prm);
    if saveData; save(filenameParam,"prm"); end
end

%% ── 3. GENERATE TRAINING DATA (skipped when useSavedData=true) ───────────
if ~useSavedData
    prmTrain                = prm;
    prmTrain.NumUELocations = 20e3;
    prmTrain.Seed           = 42;
    disp("Generating training data …")
    [optBeamPairIdxTrain, rsrpMatTrain, dataTrain] = hGenData38901Channel(prmTrain);
    disp("Done.")
    if saveData; save(filenameTrainData,"optBeamPairIdxTrain","rsrpMatTrain","dataTrain"); end
end

%% ── 4. GENERATE TEST DATA (skipped when useSavedData=true) ──────────────
if ~useSavedData
    prmTest                = prm;
    prmTest.NumUELocations = 700;
    prmTest.Seed           = 24;
    disp("Generating test data …")
    [optBeamPairIdxTest, rsrpMatTest, dataTest] = hGenData38901Channel(prmTest);
    disp("Done.")
    if saveData; save(filenameTestData,"optBeamPairIdxTest","rsrpMatTest","dataTest"); end
end

%% ── 5. PLOT UE & BS LOCATIONS ────────────────────────────────────────────
positionsUE = {dataTrain.PosUE, dataTest.PosUE};
positionsBS = {dataTrain.PosBS, dataTest.PosBS};
plotLocations(positionsUE, positionsBS, prm.InterSiteDistance);

%% ── 6. PROCESS DATA ──────────────────────────────────────────────────────
optBeamPairIdxScalarTrain = processData(prm, rsrpMatTrain);
optBeamPairIdxScalarTest  = processData(prm, rsrpMatTest);

% Split off 10 % validation set
totalTrainSamples = dataTrain.NumUELocations;
valDataLen        = round(0.1 * totalTrainSamples);

rng(111)
shuffledIdx      = randperm(totalTrainSamples);
rsrpMatTrain     = rsrpMatTrain(:,:,shuffledIdx);
locationMatTrain = dataTrain.PosUE(shuffledIdx, :);

rsrpMatVal            = rsrpMatTrain(:,:,1:valDataLen);
rsrpMatTrainMinusVal  = rsrpMatTrain(:,:,valDataLen+1:end);
trainLocs             = locationMatTrain(valDataLen+1:end, :);

%% ── 7. CREATE NN INPUT / OUTPUT (normalise → reshape → downsample) ───────
numBeamPairs    = prm.NumRxBeams * prm.NumTxBeams;
numSampledBeams = 14;
downsampleStep  = round(numBeamPairs / numSampledBeams);

globalMax  = max(abs(rsrpMatTrainMinusVal), [], "all");
globalMax  = max(globalMax, eps);
normalize  = @(x) x / globalMax;

rsrpMatTrainNorm = normalize(rsrpMatTrainMinusVal);
rsrpMatValNorm   = normalize(rsrpMatVal);
rsrpMatTestNorm  = normalize(rsrpMatTest);

vec = @(x) reshape(x, numBeamPairs, []);   % (RxBeams×TxBeams) × N

rsrpTrainVec   = vec(rsrpMatTrainNorm);
rsrpTrainInput = rsrpTrainVec(1:downsampleStep:end, :);

rsrpValVec   = vec(rsrpMatValNorm);
rsrpValInput = rsrpValVec(1:downsampleStep:end, :);

rsrpTestVec   = vec(rsrpMatTestNorm);
rsrpTestInput = rsrpTestVec(1:downsampleStep:end, :);

testLocs = dataTest.PosUE;

%% ── 8. HISTOGRAM OF OPTIMAL BEAM PAIRS ──────────────────────────────────
data = {optBeamPairIdxScalarTrain(valDataLen+1:end), ...
        optBeamPairIdxScalarTrain(1:valDataLen), ...
        optBeamPairIdxScalarTest};
plotBeamPairsHist(data);

%% ── 9. LOAD OR TRAIN NEURAL NETWORK ──────────────────────────────────────
trainNow    = false;   % set true to retrain from scratch
saveNet     = false;
filenameNet = "nnBS_trainedNet.mat";

if ~trainNow
    load(filenameNet);   % loads: net, netinfo
end

if trainNow
    layers = dlnetwork([ ...
        featureInputLayer(numSampledBeams, Name="input")
        fullyConnectedLayer(64,  Name="linear1"); reluLayer(Name="relu1")
        fullyConnectedLayer(128, Name="linear2"); reluLayer(Name="relu2")
        fullyConnectedLayer(256, Name="linear3"); reluLayer(Name="relu3")
        fullyConnectedLayer(128, Name="linear4"); reluLayer(Name="relu4")
        fullyConnectedLayer(numBeamPairs, Name="linear5")
        tanhLayer(Name="tanh1")]);

    maxEpochs     = 500;
    miniBatchSize = 200;

    if canUseGPU();         execEnv = "gpu";
    elseif canUseParallelPool(); execEnv = "parallel-auto";
    else;                   execEnv = "cpu";
    end

    options = trainingOptions("adam", ...
        MaxEpochs           = maxEpochs, ...
        MiniBatchSize       = miniBatchSize, ...
        InitialLearnRate    = 1e-4, ...
        LearnRateSchedule   = "piecewise", ...
        LearnRateDropPeriod = 10, ...
        LearnRateDropFactor = 0.8, ...
        ValidationData      = {rsrpValInput, rsrpValVec}, ...
        ValidationFrequency = 500, ...
        OutputNetwork       = "best-validation-loss", ...
        InputDataFormats    = "CB", ...
        TargetDataFormats   = "CB", ...
        Shuffle             = "every-epoch", ...
        Plots               = "training-progress", ...
        Verbose             = false, ...
        ExecutionEnvironment= execEnv);

    [net, netinfo] = trainnet(rsrpTrainInput, rsrpTrainVec, ...
        layers, @(x,t) mse(x,t), options);

    if saveNet; save(filenameNet,"net","netinfo"); end
    disp(netinfo);
end

%% ── 10. EVALUATE: TOP-K ACCURACY ─────────────────────────────────────────
rng(111)
statisticCount  = accumarray(optBeamPairIdxScalarTrain, 1, [numBeamPairs, 1]);
predTestOutput  = predict(net, rsrpTestInput, ...
    InputDataFormats="CB", OutputDataFormats="CB");

K           = numBeamPairs;
testDataLen = size(rsrpMatTestNorm, 3);
accNeural   = zeros(1,K);
accKNN      = zeros(1,K);
accStatistic= zeros(1,K);
accRandom   = zeros(1,K);

for k = 1:K
    predCorrectNeural  = zeros(testDataLen,1);
    predCorrectKNN     = zeros(testDataLen,1);
    predCorrectStats   = zeros(testDataLen,1);
    predCorrectRandom  = zeros(testDataLen,1);
    knnIdx = knnsearch(trainLocs, testLocs, K=k);

    for n = 1:testDataLen
        [~, trueOptBeamIdx] = max(rsrpMatTest(:,:,n), [], "all", "linear");

        % Neural Network
        [~, topK] = maxk(predTestOutput(:,n), k);
        predCorrectNeural(n) = any(topK == trueOptBeamIdx);

        % KNN
        topK = optBeamPairIdxScalarTrain(knnIdx(n,:));
        predCorrectKNN(n) = any(topK == trueOptBeamIdx);

        % Statistical
        [~, topK] = maxk(statisticCount, k);
        predCorrectStats(n) = any(topK == trueOptBeamIdx);

        % Random
        topK = randperm(numBeamPairs, k);
        predCorrectRandom(n) = any(topK == trueOptBeamIdx);
    end

    accuracy          = @(x) nnz(x)/testDataLen*100;
    accNeural(k)      = accuracy(predCorrectNeural);
    accKNN(k)         = accuracy(predCorrectKNN);
    accStatistic(k)   = accuracy(predCorrectStats);
    accRandom(k)      = accuracy(predCorrectRandom);
end

results = {accNeural, accKNN, accStatistic, accRandom};
plotResults(results, K);
ylabel("Top-$K$ Accuracy (\%)", Interpreter="latex");
legend("Neural Network","KNN","Statistical Info","Random", Location="best");

%% ── 11. EVALUATE: AVERAGE RSRP ───────────────────────────────────────────
rng(111)
rsrpOptimal   = zeros(1,K);
rsrpNeural    = zeros(1,K);
rsrpKNN       = zeros(1,K);
rsrpStatistic = zeros(1,K);
rsrpRandom    = zeros(1,K);

for k = 1:K
    rsrpSumOpt=0; rsrpSumNeural=0; rsrpSumKNN=0;
    rsrpSumStatistic=0; rsrpSumRandom=0;
    knnIdx = knnsearch(trainLocs, testLocs, K=k);

    for n = 1:testDataLen
        rsrp = rsrpMatTest(:,:,n);

        [~, trueOptBeamIdx] = max(rsrpTestVec(:,n));
        rsrpSumOpt = rsrpSumOpt + rsrp(trueOptBeamIdx);

        [~, topK] = maxk(predTestOutput(:,n), k);
        rsrpSumNeural = rsrpSumNeural + max(rsrp(topK));

        topK = optBeamPairIdxScalarTrain(knnIdx(n,:));
        rsrpSumKNN = rsrpSumKNN + max(rsrp(topK));

        [~, topK] = maxk(statisticCount, k);
        rsrpSumStatistic = rsrpSumStatistic + max(rsrp(topK));

        topK = randperm(numBeamPairs, k);
        rsrpSumRandom = rsrpSumRandom + max(rsrp(topK));
    end

    rsrpOptimal(k)   = rsrpSumOpt      / testDataLen;
    rsrpNeural(k)    = rsrpSumNeural   / testDataLen;
    rsrpKNN(k)       = rsrpSumKNN      / testDataLen;
    rsrpStatistic(k) = rsrpSumStatistic/ testDataLen;
    rsrpRandom(k)    = rsrpSumRandom   / testDataLen;
end

results = {rsrpNeural, rsrpKNN, rsrpStatistic, rsrpRandom, rsrpOptimal};
plotResults(results, K);
ylabel("Average RSRP");
legend("Neural Network","KNN","Statistical Info","Random","Exhaustive Search", Location="best");

table(rsrpOptimal(end-3:end)', rsrpNeural(end-3:end)', rsrpKNN(end-3:end)', ...
    VariableNames=["Optimal","Neural Network","KNN"])

%% ════════════════════════════════════════════════════════════════════════
%  LOCAL FUNCTIONS  (must stay in this file)
%% ════════════════════════════════════════════════════════════════════════

function prm = validateParams(prm)
    if strcmpi(prm.FrequencyRange,"FR1")
        if prm.CenterFrequency > 7.125e9 || prm.CenterFrequency < 410e6
            error("Center frequency outside FR1 range.");
        end
        if any(strcmpi(prm.SSBlockPattern,["Case D","Case E"]))
            error("Invalid SSBlockPattern for FR1.");
        end
        if prm.CenterFrequency <= 3e9 && length(prm.SSBTransmitted)~=4
            error("SSBTransmitted must have length 4 for CF ≤ 3 GHz.");
        end
        if prm.CenterFrequency > 3e9 && length(prm.SSBTransmitted)~=8
            error("SSBTransmitted must have length 8 for 3 GHz < CF ≤ 7.125 GHz.");
        end
    else
        if prm.CenterFrequency > 52.6e9 || prm.CenterFrequency < 24.25e9
            error("Center frequency outside FR2 range.");
        end
        if ~any(strcmpi(prm.SSBlockPattern,["Case D","Case E"]))
            error("SSBlockPattern must be Case D or Case E for FR2.");
        end
    end

    prm.NumTx = getNumElements(prm.TransmitAntennaArray);
    prm.NumRx = getNumElements(prm.ReceiveAntennaArray);
    if prm.NumTx==1 || prm.NumRx==1
        error("Need >1 TX and RX antenna elements.");
    end

    if prm.FrequencyRange=="FR1"; maxNumSSBBlocks=8; else; maxNumSSBBlocks=64; end

    if isempty(prm.NumSSBlocks)
        azTxBW = beamwidth(prm.TransmitAntennaArray, prm.CenterFrequency, Cut="Azimuth");
        numAZTxBeams = round(diff(prm.TxAZlim)/azTxBW);
        if prm.ElevationSweep
            elTxBW = beamwidth(prm.TransmitAntennaArray, prm.CenterFrequency, Cut="Elevation");
            numELTxBeams = round(diff(prm.TxELlim)/elTxBW);
        else
            numELTxBeams = 1;
        end
        prm.NumTxBeams = min(numAZTxBeams*numELTxBeams, maxNumSSBBlocks);
        prm.NumSSBlocks = prm.NumTxBeams;
    else
        if prm.NumSSBlocks > maxNumSSBBlocks
            error("Too many SSB blocks for " + prm.FrequencyRange);
        end
        prm.NumTxBeams = prm.NumSSBlocks;
    end
    prm.SSBTransmitted = [ones(1,prm.NumTxBeams) zeros(1,maxNumSSBBlocks-prm.NumTxBeams)];

    azRxBW = beamwidth(prm.ReceiveAntennaArray, prm.CenterFrequency, Cut="Azimuth");
    numAZRxBeams = round(diff(prm.RxAZlim)/azRxBW);
    if prm.ElevationSweep
        elRxBW = beamwidth(prm.ReceiveAntennaArray, prm.CenterFrequency, Cut="Elevation");
        numELRxBeams = round(diff(prm.RxELlim)/elRxBW);
    else
        numELRxBeams = 1;
    end
    prm.NumRxBeams = min(numAZRxBeams*numELRxBeams, 8);

    switch lower(prm.SSBlockPattern)
        case "case a";           scs=15;  cbw=10;  scsCommon=15;
        case {"case b","case c"};scs=30;  cbw=25;  scsCommon=30;
        case "case d";           scs=120; cbw=100; scsCommon=120;
        case "case e";           scs=240; cbw=200; scsCommon=120;
    end
    prm.SCS=scs; prm.ChannelBandwidth=cbw; prm.SubcarrierSpacingCommon=scsCommon;

    txBurst = nrWavegenSSBurstConfig;
    txBurst.BlockPattern          = prm.SSBlockPattern;
    txBurst.TransmittedBlocks     = prm.SSBTransmitted;
    txBurst.Period                = 20;
    txBurst.SubcarrierSpacingCommon = prm.SubcarrierSpacingCommon;
    prm.TxBurst = txBurst;
end

function optBeamPairIdxScalar = processData(prm, rsrpMat)
    numBeamPairs   = prm.NumRxBeams * prm.NumTxBeams;
    rsrpReshaped   = reshape(rsrpMat, numBeamPairs, []);
    [~, optBeamPairIdxScalar] = max(rsrpReshaped, [], 1);
    optBeamPairIdxScalar = optBeamPairIdxScalar(:);
end

function plotLocations(positionsUE, positionsBS, ISD)
    [sitex,sitey] = h38901Channel.sitePolygon(ISD);
    t = tiledlayout(TileSpacing="compact", GridSize=[1,2]);
    titles = ["Training Data","Testing Data"];
    for idx = 1:2
        nexttile
        plot(sitex,sitey,"--"); box on; hold on
        plot(positionsUE{idx}(:,1), positionsUE{idx}(:,2), "b.")
        plot(positionsBS{idx}(:,1), positionsBS{idx}(:,2), "^", ...
            MarkerEdgeColor="r", MarkerFaceColor="r")
        xlabel("x (m)"); ylabel("y (m)")
        xlim([min(sitex)-10 max(sitex)+10])
        ylim([min(sitey)-10 max(sitey)+10])
        axis("square"); title(titles(idx))
    end
    title(t,"Transmitter and UEs 2-D Positions")
    l = legend("Cell boundaries","UEs","Transmitter");
    l.Layout.Tile = "south";
end

function plotBeamPairsHist(data)
    t = tiledlayout(2,2,"TileSpacing","compact");
    titles    = ["Training Data","Validation Data","Testing Data"];
    tileSpecs = {[1 2], 3, 4};
    for idx = 1:3
        nexttile(tileSpecs{idx})
        histogram(data{idx}); title(titles(idx))
    end
    title(t,"Histogram of Optimal Beam Pair Indices")
    xlabel(t,"Beam Pair Index"); ylabel(t,"Number of Occurrences")
end

function plotResults(results, K)
    figure; lineWidth=1.5;
    markerStyle = ["*","o","s","d","h"];
    hold on
    for idx = 1:numel(results)
        plot(1:K, results{idx}, LineStyle="--", LineWidth=lineWidth, Marker=markerStyle(idx))
    end
    hold off; grid on
    xticks([1 3 5 10 15:5:K])
    xlabel("$K$", Interpreter="latex")
    title("Performance Comparison of Different Beam Pair Selection Methods")
end