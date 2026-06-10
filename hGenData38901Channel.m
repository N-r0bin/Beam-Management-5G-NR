function [optBeamPairIdx,rsrpMat,dataInfo] = hGenData38901Channel(prm,useParallel)
    % hGenData38901Channel Generate data for beam selection and beam
    % prediction examples

    %   Copyright 2024-2026 The MathWorks, Inc.

    arguments
        prm (1,1) struct
        useParallel (1,1) logical = false;
    end

    c = physconst('LightSpeed');   % Propagation speed

    % Extract parameter fields that are needed later on in the function
    prm = validateParameters(prm);
    numTxBeams = prm.NumTxBeams;
    numRxBeams = prm.NumRxBeams;
    ncellid = prm.NCellID;
    txBurst = prm.TxBurst;

    %% Burst Generation

    % Configure an nrDLCarrierConfig object to use the synchronization signal
    % burst parameters and to disable other channels. This object will be used
    % by nrWaveformGenerator to generate the SS burst waveform.
    cfgDL = configureWaveformGenerator(prm,txBurst);

    % Generate burst waveform
    burstWaveform = nrWaveformGenerator(cfgDL);
    burstWaveform = single(burstWaveform); % Convert to single for speedup

    %% OFDM Information

    % Get carrier object
    carrier = nrCarrierConfig('NCellID',ncellid);
    carrier.NSizeGrid = cfgDL.SCSCarriers{1}.NSizeGrid;
    carrier.SubcarrierSpacing = cfgDL.SCSCarriers{1}.SubcarrierSpacing;

    % Get OFDM information
    ofdmInfo = nrOFDMInfo(carrier);

    %% Transmit-End Beam Sweeping
    % Transmit beam angles in azimuth and elevation, equispaced
    arrayTx = prm.TransmitAntennaArray;
    azBW = beamwidth(arrayTx,prm.CenterFrequency,'Cut','Azimuth');
    elBW = beamwidth(arrayTx,prm.CenterFrequency,'Cut','Elevation');
    txBeamAng = hGetBeamSweepAngles(numTxBeams,prm.TxAZlim,prm.TxELlim, ...
        azBW,elBW,prm.ElevationSweep);
    % Account for the antenna downtilt
    elOffset = 90 - prm.TxDowntilt;
    txBeamAng(2,:) = txBeamAng(2,:) + elOffset;

    % For evaluating transmit-side steering weights
    SteerVecTx = phased.SteeringVector(SensorArray=arrayTx,PropagationSpeed=c);

    % Get the set of OFDM symbols and subcarriers occupied by each SSB
    [burstOccupiedSymbols,~] = getBurstOccupiedResources(carrier,txBurst);

    % Apply steering per OFDM symbol for each SSB
    gridSymLengths = repmat(ofdmInfo.SymbolLengths,1,cfgDL.NumSubframes);
    %   repeat burst over numTx to prepare for steering
    strTxWaveform = repmat(burstWaveform,1,prm.NumTx)./sqrt(prm.NumTx);
    wT = nan(prm.NumTx,numTxBeams);
    for txBeamIdx = 1:numTxBeams

        % Extract SSB waveform from burst
        blockSymbols = burstOccupiedSymbols(txBeamIdx,:);
        startSSBInd = sum(gridSymLengths(1:blockSymbols(1)-1))+1;
        endSSBInd = sum(gridSymLengths(1:blockSymbols(4)));
        ssbWaveform = strTxWaveform(startSSBInd:endSSBInd,1);

        % Generate weights for steered direction
        wT(:,txBeamIdx) = SteerVecTx(prm.CenterFrequency,txBeamAng(:,txBeamIdx));

        % Beamforming: Apply weights per transmit element to SSB
        strTxWaveform(startSSBInd:endSSBInd,:) = ssbWaveform*wT(:,txBeamIdx)';

    end

    % Adjust the beamformed waveform according to the base station power
    pref = sum(rms(strTxWaveform).^2);
    txWaveform = strTxWaveform*1/sqrt(pref)*sqrt(10^((prm.PowerBSs-30)/10));

    %% Receive-End Beam Sweeping and Measurement
    % Receive beam angles in azimuth and elevation, equispaced
    arrayRx = prm.ReceiveAntennaArray;
    azBW = beamwidth(arrayRx,prm.CenterFrequency,'Cut','Azimuth');
    elBW = beamwidth(arrayRx,prm.CenterFrequency,'Cut','Elevation');
    rxBeamAng = hGetBeamSweepAngles(numRxBeams,prm.RxAZlim,prm.RxELlim, ...
        azBW,elBW,prm.ElevationSweep);

    % For evaluating receive-side steering weights
    SteerVecRx = phased.SteeringVector(SensorArray=arrayRx,PropagationSpeed=c);
    wR = nan(prm.NumRx,numRxBeams);
    for rxBeamIdx = 1:numRxBeams
        wR(:,rxBeamIdx) = SteerVecRx(prm.CenterFrequency,rxBeamAng(:,rxBeamIdx));
    end

    %% Processing loop for each UE

    % Setup trajectory generation
    [cfg38901,siteBoundaries,dataInfo_tmp] = setupTrajectoryGeneration(prm,ofdmInfo.SampleRate);

    % The function loops over all receive locations to generate the data.
    % Note that, in this case, each separate location is represented as a
    % separate UE.
    numUEs = prm.NumTrajectories;
    isMobility = prm.ue.Mobility;

    % Pre-allocate outputs
    if isMobility
        % For mobility cases, the outputs are cell arrays with numUEs
        % elements
        rsrpMat_tmp = cell(numUEs,1); % This needs special handling to adhere to the parfor requirements
        optBeamPairIdx = cell(numUEs,1);
    else
        rsrpMat = zeros(numRxBeams,numTxBeams,numUEs,"single");
        optBeamPairIdx = nan(numUEs,1);
    end

    disp("  Total iterations: " + numUEs)
    % To enable the use of parallel computing for increased speed set the
    % value of |useParallel| to true. This needs the Parallel Computing
    % Toolbox (TM). If this is not installed 'parfor' will default to the
    % normal 'for' statement.
    parfor (ue = 1:numUEs, useParallel*numUEs)
        if mod(ue, 10)==1 || isMobility
            disp("  Iteration count = " + ue);
        end

        % Copy broadcast parameters to avoid extra parfor overhead. Pass
        % the loop id to handle the RNG state.
        [prm_local,cfg38901_local,wR_local] = getLocalVariables(prm,cfg38901,wR,ue);

        % Generate dummy values for variables that are used after the while
        % loop to ensure that parfor doesn't throw any "Uninitialized
        % Temporaries" warning
        thisRsrpMat = -inf;
        thisOptBeamPairIdx = nan;
        thisDataInfo = defineDataTemplate();

        isUEValid = false;
        while ~isUEValid
            % Compute the trajectories and the channels related to them. In
            % case of static UEs, UE locations are expressed as
            % trajectories with a single point at time 0.
            [thisTrajectory,thisChannel,thisDataInfo] = computeTrajectories(setfield(prm_local,'NumTrajectories',1), ...
                cfg38901_local,siteBoundaries); %#ok<SFLD>

            % Pad the waveform to ensure the channel filter is fully flushed
            chInfo = info(thisChannel.SmallScale);
            maxChDelay = chInfo.MaximumChannelDelay;
            nT = size(txWaveform,2);
            dlWaveform = [txWaveform; zeros(maxChDelay,nT)];

            % Loop over each time instance in the trajectory
            [thisOptBeamPairIdx,thisRsrpMat,thisDataInfo,isUEValid] = processTrajectory(...
                dlWaveform,...                                    % Data (waveform)
                thisChannel,thisTrajectory,thisDataInfo,...       % UE-related info
                prm_local,carrier,ofdmInfo,maxChDelay,wR_local);  % Additional parameters
        end

        % Assign the data info structure to the current UE
        dataInfo_tmp(ue) = thisDataInfo;

        % Assign the measurements results for this trajectory to the output
        % variables
        if isMobility
            rsrpMat_tmp{ue} = thisRsrpMat;
            optBeamPairIdx{ue} = thisOptBeamPairIdx;
        else
            rsrpMat(:,:,ue) = thisRsrpMat;
            optBeamPairIdx(ue) = thisOptBeamPairIdx;
        end
    end

    if isMobility
        rsrpMat = rsrpMat_tmp;
        dataInfo = dataInfo_tmp;
    else
        % Update the dataInfo output structure
        dataInfo = defineDataTemplate();
        dataInfo.Seed = uint32(cat(1,dataInfo_tmp.Seed));
        dataInfo.PosBS = dataInfo_tmp(1).PosBS;
        dataInfo.NumUELocations = numUEs;
        dataInfo.PosUE = single(cat(1,dataInfo_tmp.PosUE));
        dataInfo.Outdoor = reshape([dataInfo_tmp.Outdoor],[],1);
        dataInfo.LOS = reshape([dataInfo_tmp.LOS],[],1);
        dataInfo.TransmitArrayOrientation = single(cat(1,dataInfo_tmp.TransmitArrayOrientation));
        dataInfo.ReceiveArrayOrientation = single(cat(1,dataInfo_tmp.ReceiveArrayOrientation));
    end
end

%% Local Functions
function prm = validateParameters(prm)
    % Check whether the input parameters are related to a mobility-based
    % simulation (i.e., time-domain beam prediction) or not (i.e.,
    % spatial-domain beam prediction)
    prm.ue.Mobility = isfield(prm,"ue"); % For mobility-based simulations, the input parameter structure must have a field called "ue"
    if ~prm.ue.Mobility
        % Update prm to add mobility parameters, even though the mobility
        % is zero. This will make the overall code flow
        prm.NumTrajectories = prm.NumUELocations;
        prm.ue.MinDistance2D = 0; % meters
        prm.ue.Speed = 0; % km/h
        prm.ue.RotationSpeed = 0; % RPM
        prm.ue.MaxTrajectoryDuration = 0; % s
        prm.ue.MinTrajectoryDuration = 0; % s
        prm.ue.TimeStep = 0.1; % Nonzero time step, to avoid empty trajectory time, in seconds
        prm.ue.SpatialConsistency = true; % Static spatial consistency
    end
end

function [burstOccupiedSymbols,burstOccupiedSubcarriers] = getBurstOccupiedResources(carrier,txBurst)
    numBlocks = length(txBurst.TransmittedBlocks);
    burstStartSymbols = hSSBurstStartSymbols(txBurst.BlockPattern,numBlocks);
    burstStartSymbols = burstStartSymbols(txBurst.TransmittedBlocks==1);
    burstOccupiedSymbols = burstStartSymbols.' + (1:4);
    burstOccupiedSubcarriers = carrier.NSizeGrid*6 + (-119:120).';
end

function cfgDL = configureWaveformGenerator(prm,txBurst)
    % Configure an nrDLCarrierConfig object to be used by nrWaveformGenerator
    % to generate the SS burst waveform.

    % Calculate the minimum number of subframes for the given number of
    % transmitted blocks to avoid generating a waveform that is longer than
    % needed
    carrier = nrCarrierConfig(SubcarrierSpacing=prm.SCS);
    symbolsPerSubframe = carrier.SymbolsPerSlot*carrier.SlotsPerSubframe;
    numBlocks = length(txBurst.TransmittedBlocks);
    burstStartSymbols = hSSBurstStartSymbols(txBurst.BlockPattern,numBlocks);
    burstStartSymbols = burstStartSymbols(txBurst.TransmittedBlocks==1);
    burstOccupiedSymbols = burstStartSymbols.' + (1:4);
    numSubframes = ceil(burstOccupiedSymbols(prm.NumSSBlocks,end)/symbolsPerSubframe);

    % For mobility-based simulations, ensure that the waveform is shorter
    % than the time step used to advance the trajectory
    if prm.ue.Mobility && (numSubframes*1e-3 > prm.ue.TimeStep)
        error("Time step used for trajectory generation (" + prm.ue.TimeStep + ...
            "s) must be greater than the waveform length (" + ...
            numSubframes*1e-3 + "s).");
    end

    cfgDL = nrDLCarrierConfig;
    cfgDL.SCSCarriers{1}.SubcarrierSpacing = prm.SCS;
    cfgDL.SCSCarriers{1}.NSizeGrid = 20; % Make the grid as tight as possible around the SSB for speedup
    if (prm.SCS==240)
        cfgDL.SCSCarriers = [cfgDL.SCSCarriers cfgDL.SCSCarriers];
        cfgDL.SCSCarriers{2}.SubcarrierSpacing = prm.SubcarrierSpacingCommon;
        cfgDL.BandwidthParts{1}.SubcarrierSpacing = prm.SubcarrierSpacingCommon;
    else
        cfgDL.BandwidthParts{1}.SubcarrierSpacing = prm.SCS;
    end
    cfgDL.BandwidthParts{1}.NSizeBWP = cfgDL.SCSCarriers{1}.NSizeGrid;
    cfgDL.PDSCH{1}.Enable = false;
    cfgDL.PDCCH{1}.Enable = false;
    cfgDL.ChannelBandwidth = prm.ChannelBandwidth;
    cfgDL.FrequencyRange = prm.FrequencyRange;
    cfgDL.NCellID = prm.NCellID;
    cfgDL.NumSubframes = numSubframes;
    cfgDL.WindowingPercent = 0;
    cfgDL.SSBurst = txBurst;

end

function rxWaveform = hAWGN(rxWaveform,noiseFigure,sampleRate,rs)
    % Add noise to the received waveform

    persistent kBoltz;
    if isempty(kBoltz)
        kBoltz = physconst('Boltzmann');
    end

    % Calculate the required noise power spectral density
    NF = 10^(noiseFigure/10);
    N0 = sqrt(kBoltz*sampleRate*290*NF);

    % Establish dimensionality based on the received waveform
    [T,Nr] = size(rxWaveform);

    % Create noise
    noise = N0*randn(rs,[T Nr],'like',1i);

    % Add noise to the received waveform
    rxWaveform = rxWaveform + noise;
end

function [ch,dataInfo] = updateChannel(ch,traj,dataInfo,tidx,spatialConsistency)
    % Update channel according to trajectory up to the next "time of interest"

    if any(strcmpi(spatialConsistency,{'ProcedureA','ProcedureB'})) % In this context, this is equivalent to say that isMobility=true
        d_step = 1; % Distance for spatially-consistent channel updates in meters
        omega = traj.RotationSpeed; % Rotational speed in RPM
        posBS = dataInfo(1).PosBS;
        pos = traj.Position(tidx,:);
        vel = traj.VelocityDirection(tidx,:)./norm(traj.VelocityDirection(tidx,:))*traj.Speed;
        cfg = struct(SpatialConsistency=spatialConsistency,UpdateDistance=d_step);
        BS = struct(Position=posBS,Velocity=[0 0 0],RotationVelocity=[0; 0; 0]); % BS does not move
        UE = struct(Position=pos,Velocity=vel,RotationVelocity=[omega; omega; omega]);

        % Apply spatial consistency update
        if (tidx==1)
            h38901Channel.createChannelLink(setfield(ch.ChannelConfiguration,SitePositions=BS.Position));
        end
        ch = h38901Channel.spatiallyConsistentMobility(ch,cfg,traj.Time(tidx),BS,UE); % this function also updates ch.SmallScale.InitialTime

        % Update LOS value
        dataInfo.LOS(tidx) = ch.SmallScale.HasLOSCluster && dataInfo.Outdoor;

        % Update BS and UE orientation at this point
        dataInfo.TransmitArrayOrientation(tidx,:) = ch.SmallScale.TransmitArrayOrientation(:)';
        dataInfo.ReceiveArrayOrientation(tidx,:) = ch.SmallScale.ReceiveArrayOrientation(:)';
    end

end

function out = defineTrajectoryTemplate()
    out = struct(Speed=double.empty,RotationSpeed=double.empty,...
        Time=double.empty,Position=double.empty(0,3),VelocityDirection=double.empty(0,1));
end

function out = defineDataTemplate()
    out = struct(NumUELocations=double.empty,NumTrajectories=double.empty,Seed=double.empty,...
        PosBS=double.empty(0,3),PosUE=double.empty(0,3),...
        Outdoor=double.empty(0,1),LOS=double.empty(0,1),...
        TransmitArrayOrientation=double.empty(0,3),ReceiveArrayOrientation=double.empty(0,3),...
        Trajectory=defineTrajectoryTemplate());
end

function [cfg38901,siteBoundaries,dataInfo] = setupTrajectoryGeneration(prm,sampleRate)

    % Define parameters needed to compute 38.901 scenario and trajectories
    dataInfo = repmat(defineDataTemplate(),1,prm.NumTrajectories); % This needs special handling to adhere to the parfor requirements

    % Get the cell boundaries
    [x,y] = h38901Channel.sitePolygon(prm.InterSiteDistance);
    siteBoundaries = [x; y];

    % Generate the 38901 scenario class
    if prm.ue.Mobility
        % In the mobility scenario, all UEs are outdoor
        indoorRatio = 0;
    else
        % If the UEs are static, their indoor/outdoor position is
        % determined using TR 38.901 Tables 7.2-1 and 7.2-3.
        indoorRatio = [];
    end

    s38901 = h38901Scenario(Scenario=prm.Scenario,...
        IndoorRatio=indoorRatio,...
        CarrierFrequency=prm.CenterFrequency,...
        InterSiteDistance=prm.InterSiteDistance,...
        NumCellSites=1,...
        NumSectors=3,...
        NumUEs=1,...
        ChosenUEs=true,...
        SpatialConsistency=prm.ue.SpatialConsistency,...
        Wrapping=false);

    % Create input structure to the channel link creation function
    channelLinksInputS = struct(...
        SampleRate=sampleRate,...
        DropMode="PathLoss",...
        TransmitAntennaArray=hPhasedToNRArray(prm.TransmitAntennaArray,prm.Lambda),...
        ReceiveAntennaArray=hPhasedToNRArray(prm.ReceiveAntennaArray,prm.Lambda),...
        FastFading=true,...
        EvaluatePathLoss=false,...
        Site=1,...
        Sector=1);
    channelLinksInput = namedargs2cell(channelLinksInputS);

    % Initialize the 38901 scenario class to get configuration and state
    createChannelLinks(s38901,channelLinksInput{:});
    cfg38901.UEDropConfig = s38901.ChannelLinksConfig;
    cfg38901.UEDropConfig.SitePositions = [0 0 nr5g.internal.channel38901.bsHeight(prm.Scenario)];
    cfg38901.UEDropState = s38901.ChannelLinksState;
    cfg38901.ChannelLinksInput = channelLinksInput;
end

function [prm,cfg38901,wR] = getLocalVariables(prm,cfg38901,wR,ue)
    % Update the seed to account for the loop id
    seed = prm.Seed + ue;

    % Handle RNG inside the parfor loop
    prm.Seed = seed;
    prm.RandomStream = RandStream('mt19937ar',Seed=seed);

    % Update internal UE count
    cfg38901.UEDropState.theUECount = ue;
    cfg38901.UEDropState.theRandStream = RandStream('mt19937ar','Seed',seed);
end

function [trajectories,channels,data] = computeTrajectories(prm,cfg38901,siteBoundaries)
    % Extract parameter fields that are needed later on in the function
    tmax = prm.ue.MaxTrajectoryDuration; % s
    dt = prm.ue.TimeStep; % s
    v = prm.ue.Speed; % km/h
    v = v*1e3/3600; % m/s

    % Define parameters needed to compute the trajectories
    trajectoryTemplate = defineTrajectoryTemplate();
    trajectoryTemplate.Speed = v; % m/s
    trajectoryTemplate.RotationSpeed = prm.ue.RotationSpeed; % RPM
    trajectories = repmat(trajectoryTemplate,1,0);
    trajectoryTime = (0:dt:tmax)'; % Column vector
    dr = v*trajectoryTime;

    % Define data structure for each trajectory
    dataTemplate = defineDataTemplate();
    dataTemplate.NumUELocations = prm.NumTrajectories;
    dataTemplate.NumTrajectories = prm.NumTrajectories;
    dataTemplate.Seed = prm.Seed;
    data = repmat(dataTemplate,1,prm.NumTrajectories);
    if prm.ue.Mobility
        alpha = 360*rand(prm.RandomStream,prm.NumTrajectories,1); % Random direction of travel, deg
    else        
        % alpha is needed but only used for mobility simulations. Setting
        % it here to a placeholder value of the right size to avoid
        % changing the RNG value when a call to rand() is not needed.
        alpha = zeros(prm.NumTrajectories,1);
    end

    channels = [];
    NTraj = 0;
    while NTraj<prm.NumTrajectories
        [trajectories,channels,data,NTraj] = generateMultipleTrajectories(cfg38901,trajectories,channels,data,NTraj,... % Inputs used and modified in the output
            prm,trajectoryTemplate,trajectoryTime,dr,alpha,... % Input needed for trajectory generation
            siteBoundaries); % Inputs needed for 38.901 channel generation
    end
end

function [trajectories,channels,data,NTraj] = generateMultipleTrajectories(cfg38901,trajectories,channels,data,NTraj,... % Inputs used and modified in the output
        prm,trajectoryTemplate,trajectoryTime,dr,alpha,... % Input needed for trajectory generation
        siteBoundaries) % Inputs needed for 38.901 channel generation

    % Define the number of trajectories needed
    numTraj = prm.NumTrajectories-NTraj;
    cfg38901.UEDropConfig.NumUEs = numTraj;

    % Generate the channels and get the UEs positions
    [thisChannels,~,thisData] = h38901ChannelSetup(cfg38901);

    % Get BS and UE initial positions
    posBS = thisData.PosBS; % m
    posUE_start = thisData.PosUE; % m

    thisTrajectories = repmat(trajectoryTemplate,1,numTraj);
    for n = 1:numTraj
        % Generate the trajectory for the full time
        [thisTime,thisPos,thisVel]= generateSingleTrajectory(prm,posUE_start(n,:),alpha(n),dr,trajectoryTime,posBS,siteBoundaries);

        if isempty(thisTime)
            % If the trajectory time is too small, discard it
            continue;
        else
            % Assign the output trajectory
            thisTrajectories(n).Time = thisTime;
            thisTrajectories(n).Position = thisPos;
            thisTrajectories(n).VelocityDirection = thisVel;

            NTraj = NTraj + 1;

            % Update data output
            numPoints = numel(thisTime);
            data(NTraj).Trajectory = thisTrajectories(n);
            data(NTraj).PosBS = posBS;
            data(NTraj).PosUE = thisPos;
            data(NTraj).Outdoor = thisData.Outdoor(n);
            data(NTraj).LOS = repmat(thisData.LOS(n),numPoints,1);
            data(NTraj).TransmitArrayOrientation = repmat(thisData.TransmitArrayOrientation(n,:),numPoints,1);
            data(NTraj).ReceiveArrayOrientation = repmat(thisData.ReceiveArrayOrientation(n,:),numPoints,1);
        end
    end

    % Remove all invalid trajectories and add the new data to the previous loop
    dataToRemove = arrayfun(@(x)isempty(x.Time),thisTrajectories);
    thisTrajectories(dataToRemove) = [];
    thisChannels(dataToRemove) = [];
    trajectories = cat(2,trajectories,thisTrajectories);
    channels = cat(2,channels,thisChannels(1,:));

    if prm.ue.Mobility
        % For mobility simulations, display a log with progress information
        % to the user
        disp("  " + (numTraj-nnz(dataToRemove)) + "/" + numTraj + " trajectories generated.");
    end

end

function [thisTime,thisPos,thisVel] = generateSingleTrajectory(prm,posUE_start,alpha,dr,trajectoryTime,posBS,siteBoundaries)
    % Generate the trajectory for the full time

    if ~prm.ue.Mobility
        thisTime = 0;
        thisPos = posUE_start;
        thisVel = [0 0 0];
    else
        tmin = prm.ue.MinTrajectoryDuration; % s
        min_d_2D = prm.ue.MinDistance2D; % meters

        thisTime = trajectoryTime;
        thisVel = repmat([cosd(alpha), sind(alpha), 0],numel(thisTime),1); % Constant velocity direction
        thisPos = posUE_start + dr.*thisVel;

        % Remove all points that lie outside the sector boundaries
        sitex = siteBoundaries(1,:);
        sitey = siteBoundaries(2,:);
        idx = vecnorm(thisPos,2,2)<min_d_2D | ... % not greater than the minimum allowed
            thisPos(:,1)<0 | atand(thisPos(:,2)./thisPos(:,1))<-30 | atand(thisPos(:,2)./thisPos(:,1))>90 | ... % not in the first sector
            ~inpolygon(thisPos(:,1),thisPos(:,2),sitex + posBS(1,1),sitey + posBS(1,2));
        thisTime(idx) = [];
        thisPos(idx,:) = [];
        thisVel(idx,:) = [];

        % If the trajectory time is too small, discard it
        if ~isempty(thisTime) && thisTime(end)<tmin
            thisTime = [];
            thisPos = [];
            thisVel = [];
        end
    end

end

function [channels,chInfo,dataInfo] = h38901ChannelSetup(cfg38901)
    % Generate channels compliant with TR 38.901 using the scenario parameters

    % Create 38.901-compliant channels between the first sector of a
    % three-sector node and all the UEs randomly dropped in the sector
    [channels,chinfoAll] = nr5g.internal.channel38901.createChannelLinks(...
        cfg38901.UEDropConfig,cfg38901.UEDropState,cfg38901.ChannelLinksInput{:});
    chInfo = chinfoAll.AttachedUEInfo;

    % Ensure channel filtering is set to true to be able to pass the
    % waveform through the channel
    for ch = 1:numel(channels)
        channels(ch).SmallScale.ChannelFiltering = true;

        % Add transmit and receive array orientation info to the output data
        % structure
        dataInfo.TransmitArrayOrientation(ch,:) = channels(ch).SmallScale.TransmitArrayOrientation';
        dataInfo.ReceiveArrayOrientation(ch,:) = channels(ch).SmallScale.ReceiveArrayOrientation';
    end

    % Add the UE and BS positions to the output data structure, together with
    % info on whether the UE is in line of sight or not
    dataInfo.PosBS = chInfo(1).Config.BSPosition;
    dataInfo.PosUE = cat(1,chInfo.Position);
    dataInfo.Outdoor = [chInfo.d_2D_in]==0;
    % To be in perfect line of sight, the UE must be outdoor as well.
    % Note that the same information is contained in
    % channels(idx).SmallScale.HasLOSCluster
    dataInfo.LOS = [chInfo.LOS] & dataInfo.Outdoor;
end

function [thisOptBeamPairIdx,thisRsrpMat,dataInfo,isUEValid] = processTrajectory(...
        wave,...                            % Data (waveform)
        channel,trajectory,dataInfo,...     % UE-related info
        prm,carrier,ofdmInfo,maxChDelay,wR) % Additional parameters

    % Allocate output measurement variables for this trajectory
    numPoints = numel(trajectory.Time);
    thisRsrpMat = -inf(prm.NumRxBeams,prm.NumTxBeams,numPoints,"single");
    thisOptBeamPairIdx = nan(numPoints,1);

    % Loop over each time instance in the trajectory
    for tidx = 1:numPoints
        % Update channel according to trajectory up to the next "time of
        % interest"
        [channel,dataInfo] = updateChannel(channel,trajectory,dataInfo,tidx,prm.ue.SpatialConsistency);

        % Pass the waveform through the channel
        rxWaveform = channel.SmallScale(wave);
        rxWaveform = rxWaveform*db2mag(channel.LargeScale(dataInfo.PosBS,trajectory.Position(tidx,:))); % Account for the path loss

        % Apply AWGN
        rxWaveform = hAWGN(rxWaveform,prm.UENoiseFigure,ofdmInfo.SampleRate,prm.RandomStream);

        % Loop over all receive beams
        [rsrp, isUEValid] = processAllBeams(rxWaveform,prm,carrier,ofdmInfo,maxChDelay,wR);
        if ~isUEValid
            % If no synchronization can be achieved for this point in the
            % trajectory for at least one beam, discard this UE and drop a
            % new one
            return;
        end

        % Assign the RSRP value to the output matrix
        thisRsrpMat(:,:,tidx) = rsrp;

        %% Beam Determination
        [~,optBeamIdx] = max(rsrp,[],'all','linear'); % First occurrence is output
        thisOptBeamPairIdx(tidx) = optBeamIdx;
    end
end

function [rsrp,isUEValid] = processAllBeams(rxWaveform,prm,carrier,ofdmInfo,maxChDelay,wR)

    % Initialize outputs
    rsrp = -inf(prm.NumRxBeams,prm.NumTxBeams);
    isUEValid = true;

    % Get SS Burst occupied symbols and subcarriers
    [burstOccupiedSymbols,burstOccupiedSubcarriers] = getBurstOccupiedResources(carrier,prm.TxBurst);

    % Loop for each receive beams
    for rIdx = 1:prm.NumRxBeams

        % Beam combining: Apply weights per receive element
        strRxWaveform = rxWaveform*conj(wR(:,rIdx));

        % Correct timing
        offset = hSSBurstTimingOffset(strRxWaveform,carrier,ofdmInfo,burstOccupiedSymbols);
        if offset > maxChDelay
            % If the receiver cannot compute a valid timing
            % offset, the receive power of the waveform is too
            % low. Try a new UE dropping
            isUEValid = false;
            break
        end
        strRxWaveformS = strRxWaveform(1+offset:end,:);

        % OFDM Demodulate
        rxGrid = nrOFDMDemodulate(carrier,strRxWaveformS);

        % Loop over all SSBs in rxGrid (transmit end)
        for tIdx = 1:prm.NumTxBeams
            % Get each SSB grid
            rxSSBGrid = rxGrid(burstOccupiedSubcarriers, ...
                burstOccupiedSymbols(tIdx,:),:);

            % Compute the synchronization signal RSRP
            rsrp(rIdx,tIdx) = hSSBurstRSRP(rxSSBGrid,prm.NCellID,prm.TxBurst.TransmittedBlocks,tIdx,prm.RSRPMode);
        end
    end

    % Convert the output RSRP to single to avoid memory waste
    rsrp = single(rsrp);
end