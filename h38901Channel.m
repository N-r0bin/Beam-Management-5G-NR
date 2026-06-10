classdef h38901Channel < handle
%h38901Channel TR 38.901 channel model
%
%   h38901Channel properties:
%
%   Scenario           - Deployment scenario ("UMi", "UMa", "RMa", "InH",
%                        "InF-SL", "InF-DL", "InF-SH", "InF-DH", "InF-HH")
%                        (default "UMa")
%   InterSiteDistance  - Intersite distance in meters (default 500)
%   Wrapping           - Geographical distance-based wrapping (true, false)
%                        (default true)
%   SpatialConsistency - Spatial consistency ("None", "Static", 
%                        "ProcedureA", "ProcedureB") (default "None")
%   UpdateDistance     - Update distance for spatially consistent mobility
%   Seed               - Random number generator (RNG) seed (default 0)
%   OfficeType         - Office type for InH scenario ("Mixed","Open")
%                        (default "Mixed")
%   ScenarioExtents    - Location and size of the scenario
%                        (default [])
%   HallSize           - Dimensions of hall for InF scenarios
%                        (default [120 60 10])
%   ClutterSize        - Clutter size for InF scenarios (default 2)
%   ClutterDensity     - Clutter density for InF scenarios (default 0.6)
%   ClutterHeight      - Clutter height for InF scenarios (default 6)
%   AbsoluteTOA        - Absolute time of arrival (false, true) 
%                        (default false)
%   LOSProbability     - LOS probability (default [])
%   UseGPU             - Specify whether to use the GPU
%
%   h38901Channel object functions:
%
%   h38901Channel               - Create channel model
%   connectNodes                - Connect simulator nodes to channel
%   channelFunction             - Simulator custom channel function
%   createChannelLink           - Create a single channel link
%   applyBeamforming            - Apply beamforming (TXRU virtualization)
%   createAutoCorrMatrices      - Create a set of autocorrelation matrices
%   uniformAutoCorrRVs          - Generate uniformly distributed spatially 
%                                 correlated random variables
%   wrappingOffsets             - Distance offsets for wrap-around 
%                                 calculations
%   sitePolygon                 - Vertices of site boundary polygon
%   spatiallyConsistentMobility - Apply spatially consistent mobility

%   Copyright 2022-2026 The MathWorks, Inc.

    % =====================================================================
    % public interface

    properties (SetAccess=private)

        % Deployment scenario, used to determine properties of the channel
        % links ("UMi", "UMa", "RMa", "InH", "InF-SL", "InF-DL", "InF-SH",
        % "InF-DH", "InF-HH") (default "UMa")
        Scenario (1,1) string = "UMa";

        % Intersite distance in meters. Only required for UMi, UMa or RMa
        % scenarios (default 500)
        InterSiteDistance (1,1) double ...
            {mustBeReal, mustBePositive, mustBeFinite} ...
            = 500;

        % Enable wrap around calculations, as defined in Rec. ITU-R
        % M.2101-0 Attachment 2 to Annex 1. Only required for UMi, UMa or
        % RMa scenarios (default true)
        Wrapping (1,1) ...
            {mustBeNumericOrLogical} ...
            = true;

        % Spatial consistency. Set to "None" (or false) to apply no spatial
        % consistency procedure. Set to "Static" (or true) to apply 
        % TR 38.901 Section 7.6.3.1 "Spatial consistency procedure". Set to
        % "ProcedureA" or "ProcedureB" to apply Procedure A or Procedure B
        % from TR 38.901 Section 7.6.3.2 "Spatially-consistent UT/BS
        % mobility modelling" (default "None")
        SpatialConsistency (1,:) ...
            {validateSpatialConsistency(SpatialConsistency)} ...
            = "None";

        % The change in BS-to-UE distance, in meters, that will trigger the
        % spatial consistency update procedure when SpatialConsistency is
        % set to "ProcedureA" or "ProcedureB". TR 38.901 Section 7.6.3.2 
        % states that this distance "should be limited within 1 meter" 
        % (default 1.0)
        UpdateDistance (1,1) double ...
            {mustBeReal, mustBeNonnegative, mustBeFinite} ...
            = 1.0;

        % Random number generator seed (default 0)
        Seed (1,1) double ...
            {mustBeReal, mustBeInteger, mustBeNonnegative} ...
            = 0;

        % Office type for InH scenario ("Mixed", "Open") (default "Mixed")
        OfficeType (1,1) string ...
            {matlab.system.mustBeMember(OfficeType,["Mixed" "Open"])} ...
            = "Mixed";

        % Location and size of the scenario, a four-element vector of the
        % form [left bottom width height]. The elements are defined as 
        % follows:
        %   left -   The X coordinate of the left edge of the scenario in 
        %            meters
        %   bottom - The Y coordinate of the bottom edge of the scenario in 
        %            meters
        %   width  - The width of the scenario in meters, that is, the 
        %            right edge of the scenario is left + width
        %   height - The height of the scenario in meters, that is, the 
        %            top edge of the scenario is bottom + height
        % Use empty ([]) to automatically calculate the value. For UMi, UMa
        % and RMa scenarios, the value is calculated assuming that each
        % nrGNB node lies at the center of a hexagonal cell with the size
        % given by the InterSiteDistance property. For InF scenarios, the
        % value is calculated from the HallSize property assuming that the
        % hall is centered on (0,0). For InH scenarios, the value is
        % calculated from the locations of the nodes attached to the
        % simulator. (default [])
        ScenarioExtents double ...
            {mustBeReal,mustBeFinite, ...
            validateScenarioExtents(ScenarioExtents)} ...
            = [];

        % Dimensions of hall for InF scenarios, a 3-by-1 vector [L W H]
        % where L is the hall length, W is the hall width and H is the hall
        % height in meters (default [120 60 10]). Not required for UMi,
        % UMa, RMa or InH scenarios.
        HallSize (1,3) double ...
            {mustBeReal, mustBePositive, mustBeFinite} ...
            = [120 60 10];

        % Clutter size in meters for InF scenarios (default 2)
        ClutterSize (1,1) double ...
            {mustBeReal, mustBeNonnegative, mustBeFinite} ...
            = 2;

        % Clutter density for InF scenarios (0...1) (default 0.6)
        ClutterDensity (1,1) double ...
            {mustBeBetween(ClutterDensity,0,1)} ...
            = 0.6;

        % Clutter height in meters for InF scenarios (default 6)
        ClutterHeight (1,1) double ...
            {mustBeReal, mustBeNonnegative, mustBeFinite} ...
            = 6;

        % Absolute time of arrival as defined in TR 38.901 Section 7.6.9.
        % Only applicable for InF scenarios (false, true) (default false)
        AbsoluteTOA (1,1) ...
            {mustBeNumericOrLogical} ...
            = false;

        % LOS probability. A scalar between 0 and 1 giving the probability
        % that a randomly-dropped UE will be in line of sight (LOS)
        % condition. If empty, the LOS probability is determined using
        % TR 38.901 Table 7.4.2-1 (default [])
        LOSProbability double ...
            {mustBeScalarOrEmpty, mustBeBetween(LOSProbability,0,1)} ...
            = [];

        % Generate outputs on the GPU
        %   Specify whether to perform computations on the GPU by setting
        %   this property to "on", "off", or "auto". The default value is
        %   "off". Note: This option controls only whether computations are
        %   performed on the GPU. The output will always be returned on the
        %   CPU.
        UseGPU (1,:) char ...
            {matlab.system.mustBeMember(UseGPU, {'off', 'on', 'auto'})} ...
            = 'off';
    end

    properties (Access = private)
        % Parsed response from matlab.internal.parallel.resolveUseGPU(),
        % either true or false
        pUseGPU = false;
    end

    methods

        function set.Scenario(obj,val)

            persistent sv;
            if (isempty(sv))
                sv = nrPathLossConfig.Scenario_Values;
            end
            obj.Scenario = validatestring(val,sv,'h38901Channel','Scenario');

        end

        function set.UseGPU(obj,val)
            obj.UseGPU = matlab.internal.parallel.validateUseGPUOption(val);
        end
    end

    methods (Access=public)

        function channel = h38901Channel(varargin)
        % Create channel model

            % Set properties from name-value arguments
            setProperties(channel,varargin{:});

            % Set up path loss configuration
            channel.thePathLossConfig = nrPathLossConfig(Scenario=channel.Scenario);

            % Create map of attachments between UEs and BSs
            channel.theUEtoBSMap = dictionary([],[]);

            % Create map between IDs and UEs
            channel.theUEMap = dictionary([],struct());

            % Create map between IDs and BSs
            channel.theBSMap = dictionary([],struct());

            % Set up empty cache of site positions
            channel.theSitePositions = [];

            % Initialize TR 38.901 definitions
            channel.nr5g = nr5g.internal.channel38901;

            % Create map between link ID pairs and channels
            c = channel.nr5g.newChannel();
            channel.theLinkToChannelMap = dictionary([],c(false));

            % Set to true to enable GPU in simulation; set to false for code generation
            if coder.target('MATLAB')
                channel.pUseGPU = ~isempty(matlab.internal.parallel.resolveUseGPU(channel.UseGPU));
            else
                channel.pUseGPU = false;
            end

            % Create SCRVs
            channel.SCRVs = [];

        end

        function connectNodes(channel,sls,varargin)
        % connectNodes(CHANNEL,SLS) obtains the connections between
        % BSs and UEs by querying the wireless network simulator SLS.
        %
        % connectNodes(CHANNEL,SLS,SCENARIO) specifies configuration
        % properties for the channel links using scenario builder SCENARIO.
        %
        % connectNodes(CHANNEL,SLS,CHCFG) alternatively specifies
        % configuration properties for the channel links using structure
        % CHCFG, which has the following fields:
        %   Site    
        %     - A row vector specifying the 1-based site index for each 
        %       gNB.
        %   Sector
        %     - A row vector specifying the 1-based sector index for each
        %       gNB.
        %   TXRUVirtualization 
        %     - A row vector of structures specifying the antenna
        %       virtualization parameters for each gNB. The
        %       parameterization is according to TR 36.897 Section 5.2.2
        %       TXRU virtualization model option-1B. Each structure has the
        %       following fields:
        %         K    - Vertical weight vector length
        %         Tilt - Tilting angle in degrees
        %         L    - Horizontal weight vector length
        %         Pan  - Panning angle in degrees
        %       The default value is struct(K=1,Tilt=0,L=1,Pan=0).
        %   TransmitArrayOrientation 
        %     - A matrix where the columns specify the transmit antenna
        %       orientations for each gNB. See
        %       nrCDLChannel/TransmitArrayOrientation. If this field is
        %       present then the Sector field is ignored, as the Sector
        %       field is only used to determine the bearing angle alpha of
        %       the array orientation.
        %   n_fl    
        %     - A row vector specifying the 1-based floor number for each
        %       UE (1 = ground floor). Only required for UMi, UMa or RMa
        %       scenarios. If absent, floor numbers will be determined
        %       automatically from UE node heights according to TR 36.873
        %       Table 6-1.
        %   d_2D_in 
        %     - A row vector specifying the 2-D indoor distance each UE in
        %       meters. Only required for UMi, UMa or RMa scenarios. If
        %       absent, the 2-D indoor distances default to 0 for all UEs
        %       i.e. all UEs are outdoor.
        %   ReceiveArrayOrientation 
        %     - A matrix where the columns specify the receive antenna
        %       orientations for each UE. See
        %       nrCDLChannel/ReceiveArrayOrientation.
        % The order of the gNBs and UEs in the columns must be the order
        % in which the nrGNB and nrUE nodes appear in the SLS.Nodes array.
        % Alternatively if the TXRUVirtualization, n_fl, d_2D_in, 
        % TransmitArrayOrientation or ReceiveArrayOrientation field has a
        % single column, it applies to all gNBs or all UEs as appropriate.

            % Determine the number of input arguments that are not
            % name-value arguments and the position of the first name (if
            % present)
            firstnvname = find(cellfun(@(x)(ischar(x) || isstring(x)),varargin),1,'first');
            if (isempty(firstnvname))
                ninarg = nargin;
            else
                % -1 for the first NV name, +1 for obj, +1 for sls
                ninarg = firstnvname - 1 + 1 + 1;
            end

            % Get scenario builder or channel configuration structure
            if (ninarg==3)
                cfg = varargin{1};
            else % ninarg==2
                cfg = [];
            end

            % Set properties from name-value arguments; this allows the
            % hidden properties InterfererHasSmallScale, PhaseLOS_d_3D
            % and InterfererSameLinkEnd to be controlled
            setProperties(channel,varargin{firstnvname:end});

            % Record list of gNBs, connections between gNBs and UEs, and
            % other scenario information that can be established from the
            % scenario builder or the channel configuration structure
            recordNodes(channel,sls,cfg);

        end
        
        function packet = channelFunction(obj,rxinfo,packet)
        % RXPACKET = CHANNEL.channelFunction(RXINFO,TXPACKET) is the custom
        % channel function CUSTOMCHANNELFCN described in
        % wirelessNetworkSimulator/addChannelModel. Call
        % wirelessNetworkSimulator/addChannelModel and pass a handle to
        % CHANNEL.channelFunction to connect the channel model to the
        % simulator.
            
            if obj.pUseGPU
                packet.Data = gpuArray(packet.Data);
            end

            % Check if connectNodes method has been called
            if (~(size(obj.theRecordedSitePositions,2)==3))
                error('nr5g:h38901Channel:NoConnectNodes','Call the connectNodes method to connect simulator nodes to the channel before executing the simulation.');
            end

            % -------------------------------------------------------------
            % TR 38.901 Section 7.5 Steps 2 - 10
            % Get channel for the current link
            [ch,bsID,ueID,linkind] = getSLSChannel(obj,rxinfo,packet);
            % -------------------------------------------------------------

            % If the channel is empty, signifying a BS-to-BS or UE-to-UE
            % link when InterfererSameLinkEnd=false, return an empty packet
            % that will be dropped by the simulator
            if (isempty(ch))
                packet = [];
                return;
            end

            % Apply spatially consistent mobility if required
            if (isSpatiallyConsistentMobility(obj))
                ch = packetMobilitySLS(obj,ch,packet,rxinfo);
                obj.theLinkToChannelMap(linkind) = ch;
            end

            % If the small scale channel is a CDL channel
            if (~isstruct(ch.SmallScale))

                % Configure channel according to packet StartTime and
                % Duration
                ch.SmallScale.InitialTime = packet.StartTime;
                ch.SmallScale.NumTimeSamples = ceil(packet.Duration * ch.SmallScale.SampleRate);

                % ---------------------------------------------------------
                % TR 38.901 Section 7.5 Step 11
                % Execute the channel
                [pathGains,sampleTimes] = ch.SmallScale();
                pathDelays = ch.PathDelays;
                pathFilters = ch.PathFilters;

                % Apply d_3D-related term of Eq 7.5-29
                if (obj.PhaseLOS_d_3D)
                    channelInfo = info(ch.SmallScale);
                    los = strcmpi(channelInfo.ClusterTypes,'LOS');
                    pathGains = obj.nr5g.applyPhaseLOS_d_3D(ch,pathGains,los);
                end

                % Apply beamforming to the channel output, this allows for
                % TXRU virtualization
                pathGains = h38901Channel.applyBeamforming(ch.SmallScale,pathGains,ch.TXRUVirtualization);
                % ---------------------------------------------------------

                % Ensure that path gains and sample times span at least one
                % slot
                [pathGains,sampleTimes] = spanSlot(obj,bsID,ueID,pathGains,sampleTimes);

            else % LOS ray only
                
                pathGains = h38901Channel.noFastFadingPathGains(ch);
                if (ch.LargeScale.TransmitAndReceiveSwapped())
                    pathGains = permute(pathGains,[1 2 4 3]);
                end
                if (obj.PhaseLOS_d_3D)
                    pathGains = obj.nr5g.applyPhaseLOS_d_3D(ch,pathGains,true);
                end
                ch.SmallScale.TransmitAndReceiveSwapped = ch.LargeScale.TransmitAndReceiveSwapped();
                pathGains = h38901Channel.applyBeamforming(ch.SmallScale,pathGains,ch.TXRUVirtualization);
                pathDelays = ch.PathDelays;
                pathFilters = ch.PathFilters;
                sampleTimes = 0;

            end

            % For full PHY, apply small scale channel to packet data
            if (~packet.Abstraction)
                if (~isequal(pathFilters,1))
                    % Channel filtering is required as path filters are not
                    % a unit scalar
                    packet.Data = channelFiltering(ch,packet.Data,pathGains,sampleTimes);
                    T = size(packet.Data,1);
                    packet.Duration = T / ch.SmallScale.SampleRate;
                else
                    % No channel filtering is required, channel is a matrix
                    % between transmit and receive antennas
                    H = permute(pathGains,[3 4 1 2]);
                    packet.Data = packet.Data * H;
                end
            end

            % -------------------------------------------------------------
            % TR 38.901 Section 7.5 Step 12
            % Update packet power with large scale channel effects
            PLdB = ch.LargeScale.execute(packet.TransmitterPosition,rxinfo.Position,packet.CenterFrequency);
            packet.Power = packet.Power - PLdB;

            % For full PHY, apply large scale channel to packet data
            if (~packet.Abstraction)
                packet.Data = packet.Data * db2mag(-PLdB);
            end
            % -------------------------------------------------------------

            if obj.pUseGPU
                packet.Data = gather(packet.Data);
                pathGains = gather(pathGains);
            end

            % Update the channel metadata in the packet
            packet.Metadata.Channel.PathGains = pathGains;
            packet.Metadata.Channel.PathDelays = pathDelays;
            packet.Metadata.Channel.PathFilters = pathFilters;
            packet.Metadata.Channel.SampleTimes = sampleTimes;

        end

    end

    methods (Static, Access=public)

        function [channel,chinfo] = createChannelLink(chcfg)
        % [CHANNEL,CHINFO] = createChannelLink(CHCFG) creates a single 
        % channel link for channel link configuration structure CHCFG.

            if (isfield(chcfg,'SpatialConsistency'))
                chcfg.SpatialConsistency = spatialConsistencyString(chcfg.SpatialConsistency);
            end
            SCRVs = manageSCRVs();
            [channel,chinfo,SCRVs] = nr5g.internal.channel38901.createChannelLink(chcfg,SCRVs);
            manageSCRVs(SCRVs);

        end

        function pathGains = applyBeamforming(cdl,pathGains,virt)
        % PATHGAINS = applyBeamforming(CDL,PATHGAINS,VIRT) applies
        % beamforming (TXRU virtualization) to the set of path gains
        % PATHGAINS for nrCDLChannel object CDL and TXRU virtualization
        % parameters VIRT, as defined in TR 36.897 Section 5.2.2 TXRU
        % virtualization model option-1B. VIRT is a structure containing
        % the following fields:
        % K    - Vertical weight vector length
        % Tilt - Tilting angle in degrees
        % L    - Horizontal weight vector length
        % Pan  - Panning angle in degrees

            pathGains = nr5g.internal.channel38901.applyBeamforming(cdl,pathGains,virt);

        end

        function [autoCorrMatrices,firstCoord] = createAutoCorrMatrices(rs,minpos,maxpos,distances)
        % [AUTOCORRMATRICES,FIRSTCOORD] =
        % createAutoCorrMatrices(RS,MINPOS,MAXPOS,DISTANCES) returns a 3-D
        % array containing autocorrelation matrices, AUTOCORRMATRICES, and
        % the coordinate pair of the first autocorrelaton matrix element,
        % FIRSTCOORD. Each matrix (i.e. plane) of AUTOCORRMATRICES is the
        % autocorrelation matrix for an element of DISTANCES, a vector of
        % correlation distances. RS is a RandomStream object used to
        % generate the normal random variables prior to spatial filtering.
        % MINPOS and MAXPOS are the coordinate pairs of the lower-left and
        % upper-right corners of the rectangular region for which the
        % autocorrelation matrices are defined.

            [autoCorrMatrices,firstCoord] = nr5g.internal.channel38901.createAutoCorrMatrices(rs,minpos,maxpos,distances);

        end

        function rvs = uniformAutoCorrRVs(autoCorrMatrix,firstCoord,pos)
        % RVS = uniformAutoCorrRVs(AUTOCORRMATRIX,FIRSTCOORD,POS) creates
        % uniformly distributed spatially correlated random variables RVS
        % given an autocorrelaton matrix, AUTOCORRMATRIX, the coordinate
        % pair of the first autocorrelaton matrix element, FIRSTCOORD, and
        % a N-by-2 matrix of UE coordinate POS (each row is the [X Y]
        % coordinate of a UE).

            rvs = nr5g.internal.channel38901.uniformAutoCorrRVs(autoCorrMatrix,firstCoord,pos);

        end

        function offsets = wrappingOffsets(ISD,numCellSites,numSectors)
        % OFFSETS = wrappingOffsets(ISD,numCellSites,numSectors) returns
        % distance offsets OFFSETS for wrap-around calculations, according
        % to Rec. ITU-R M.2101-0 Attachment 2 to Annex 1, for a specified
        % intersite distance ISD, number of cell sites numCellSites and
        % number of sector per cell site numSectors.

            offsets = nr5g.internal.channel38901.wrappingOffsets(ISD,numCellSites,numSectors);

        end

        function [x,y] = sitePolygon(ISD)
        % [X,Y] = sitePolygon(ISD) returns vertices of the polygon that
        % forms the boundary of a site with specified intersite distance
        % ISD.

            [x,y] = nr5g.internal.channel38901.sitePolygon(ISD);

        end

        % Calculate path gains corresponding to LOS channel ray
        function pathgains = noFastFadingPathGains(varargin)
        % PATHGAINS = noFastFadingPathGains(CH) returns the path gains
        % array PATHGAINS for the LOS ray of specified channel
        % configuration structure CH. PATHGAINS is of size
        % 1-by-1-by-Nt-by-Nr where Nt is the number of transmit antennas
        % and Nr is the number of receive antennas.

            pathgains = nr5g.internal.channel38901.noFastFadingPathGains(varargin{:});

        end

        % Apply spatially consistent mobility to a channel link
        function varargout = spatiallyConsistentMobility(channel,cfg,t,tx,rx)
        % [CHANNEL,UPDATED,LOS_SOFT] = spatiallyConsistentMobility(CHANNEL,CFG,T,TX,RX)
        % applies spatially consistent mobility to input CHANNEL according
        % to configuration structure CFG, current simulation time T,
        % transmitter information structure TX, and receiver information
        % structure RX. If the output UPDATED is true, then the output
        % CHANNEL is the updated channel after a mobility update. If the
        % output UPDATED is false, then the output CHANNEL is equal to the
        % input, and no mobility update has been applied. The output 
        % LOS_SOFT provides the soft LOS state.
        %
        % CHANNEL is a channel link structure, as returned by the 
        % createChannelLink object function. 
        %
        % CFG is a structure containing the following fields:
        % SpatialConsistency - ("ProcedureA", "ProcedureB")
        % UpdateDistance     - The change in BS-to-UE distance, in meters, 
        %                      that will trigger the spatial consistency 
        %                      update procedure. TR 38.901 Section 7.6.3.2 
        %                      states that this distance "should be limited
        %                      within 1 meter" (default 1.0)
        %
        % TX and RX are structures containing the following fields:
        % Position          - Position of node, specified as a real-valued
        %                     vector in Cartesian coordinates [x y z] in 
        %                     meters
        % Velocity          - Velocity (v) of node in the x-, y-, and 
        %                     z-directions, specified as a real-valued 
        %                     vector of the form [vx vy vz] in meters per 
        %                     second
        % RotationVelocity  - Rotation velocity (ω) of the node in the 
        %                     direction of positive bearing angle α,
        %                     downtilt angle β, and slant angle γ,
        %                     specified as a real-valued vector of the form
        %                     [ωα; ωβ; ωγ] in rotations per minute (RPM).
        %                     These values are used to update the
        %                     orientation of the antenna array of the node

            SCRVs = manageSCRVs();
            [varargout{1:nargout}] = nr5g.internal.channel38901.spatiallyConsistentMobility(SCRVs,channel,cfg,t,tx,rx);

        end

    end

    % =====================================================================
    % private

    properties (SetAccess=private,Hidden)

        InterfererHasSmallScale (1,1) ...
            {mustBeNumericOrLogical} ...
            = false;
        PhaseLOS_d_3D (1,1) ...
            {mustBeNumericOrLogical} ...
            = true;
        InterfererSameLinkEnd (1,1) ...
            {mustBeNumericOrLogical} ...
            = false;

    end

    properties (Access=private)

        theLinkToChannelMap;
        thePathLossConfig;
        theUEtoBSMap;
        theUEMap;
        theBSMap;
        theRecordedSitePositions;
        theRecordedUEPositions;
        theScenarioInfo = struct(MaxBSID=NaN,Wrapping=false,SpatialConsistency=false,InterSiteDistance=NaN,NodeSiz=[1 1 1],MaxLinkID=NaN);
        theSitePositions;
        nr5g;
        SCRVs;

    end

end

%% ========================================================================
%  local functions related to wirelessNetworkSimulator
%  ========================================================================

function [channel,bsID,ueID,linkind] = getSLSChannel(obj,rxinfo,packet)

    % Get BS and UE IDs for this link and establish if the link is uplink
    % (that is, the UE is the transmitter)
    linkID = [packet.TransmitterID rxinfo.ID];
    [bsID,ueID,isUplink] = getBSandUE(obj,linkID);

    % If either the BS or UE ID is undefined, signifying a BS-to-BS or
    % UE-to-UE link, return an empty channel if InterfererSameLinkEnd=false
    if (~obj.InterfererSameLinkEnd && (isnan(bsID) || isnan(ueID)))
        channel = [];
        linkind = [];
        return;
    end

    % When InterfererSameLinkEnd=true and the link is BS-to-BS and
    % corresponds to two sectors for the same site, return an empty channel
    if (isnan(ueID))
        nodesubs = cat(1,obj.theBSMap(linkID).NodeSubs);
        sitesubs = nodesubs(:,1);
        if (sitesubs(1)==sitesubs(2))
            channel = [];
            linkind = [];
            return;
        end
    end

    % ---------------------------------------------------------------------
    % TR 38.901 Section 7.5 Steps 2 - 10
    % Get or create the channel for the appropriate link direction
    if (isnan(isUplink))
        % BS-to-BS or UE-to-UE link, do not allow reciprocity as nodes can
        % have different values for properties such as TXRUVirtualization
        % and d_2D_in
        thisLinkID = linkID;
        otherLinkID = linkID;
    elseif (isUplink)
        thisLinkID = [ueID bsID];
        otherLinkID = [bsID ueID];
    else
        thisLinkID = [bsID ueID];
        otherLinkID = [ueID bsID];
    end
    [channel,isUplink,linkind] = getSLSChannelLink(obj,thisLinkID,otherLinkID,linkID,rxinfo,packet,isUplink);

    % ---------------------------------------------------------------------

    % Now that a channel is selected, ensure that the channel is set for
    % the correct link direction. Note that channels are always created in
    % the downlink direction, so uplink links must always be configured as
    % reciprocal links (that is, with transmit and receive swapped). For
    % BS-to-BS or UE-to-UE links reciprocity is not used as nodes can have
    % different values for properties such as TXRUVirtualization and
    % d_2D_in
    if (~isnan(isUplink) && xor(isUplink,channel.LargeScale.TransmitAndReceiveSwapped()))
        channel.LargeScale.swapTransmitAndReceive();
        if (~isempty(channel.SmallScale) && ~isstruct(channel.SmallScale))
            swapTransmitAndReceive(channel.SmallScale);
        end
    end

end

% Get or create the channel for the specified link direction
function [channel,isUplink,linkindout] = getSLSChannelLink(obj,thisLinkID,otherLinkID,linkID,rxinfo,packet,isUplink)

    % If a channel exists in this link direction
    linkind = linkIndicesForID(obj,thisLinkID);
    if (isKey(obj.theLinkToChannelMap,linkind))

        % Use it
        channel = obj.theLinkToChannelMap(linkind);
        linkindout = linkind;

    else % a channel does not exist in this link direction

        % If a channel exists in the other link direction
        linkind = linkIndicesForID(obj,otherLinkID);
        if (isKey(obj.theLinkToChannelMap,linkind))

            % If the center frequencies of that channel and this packet
            % match
            ch = obj.theLinkToChannelMap(linkind);
            sameFrequency = isequal(ch.CenterFrequency,packet.CenterFrequency);
            chAnts = [ch.NumTransmitAntennas ch.NumReceiveAntennas];
            nodeAnts = [rxinfo.NumReceiveAntennas packet.NumTransmitAntennas];
            sameAnts = all(chAnts == nodeAnts);
            if (sameFrequency && sameAnts)

                % TDD and the same antenna count, the channel can be
                % re-used for this link direction - use it
                channel = ch;
                linkindout = linkind;

            else

                % FDD and/or a different antenna count, the channel cannot
                % be re-used for this link direction - create a new channel
                channel = [];

            end

        else

            % A channel does not exist for either link direction - create a
            % new channel for this link direction
            channel = [];

        end

    end

    % ---------------------------------------------------------------------
    % TR 38.901 Section 7.5 Steps 2 - 10
    if (isempty(channel))
        [channel,isUplink,linkindout] = createSLSChannelLink(obj,linkID,packet,isUplink);
    end
    % ---------------------------------------------------------------------

end

% Create a channel link for the SLS
function [channel,isUplink,linkind] = createSLSChannelLink(obj,linkID,packet,isUplink)

    % Establish if this link needs a CDL channel (that is, between two
    % nodes that are attached or InterfererHasSmallScale is true).
    % Establish the BS and UE IDs
    [attached,bsID,ueID] = isAttached(obj,linkID);
    hasSmallScale = true;
    if (obj.InterfererHasSmallScale)
        fastFading = true;
    else
        fastFading = attached;
    end

    % Prepare vectors describing node counts and subscripts, and get the
    % number of transmit and receive antennas
    if (isnan(isUplink))
        % BS-to-BS or UE-to-UE link
        if (~isnan(bsID))
            % BS-to-BS
            theMap = obj.theBSMap;
        else
            % UE-to-UE
            theMap = obj.theUEMap;
        end
        % 'f' and 'r' are the forward and reverse nodes, i.e. adopt the
        % convention that the communication path linkID(1) -> linkID(2) is
        % the forward link
        f = theMap(linkID(1));
        r = theMap(linkID(2));
        % Create 'nodeSiz' and 'nodeSubs', allowing for UEs in the forward
        % link and BSs (including sectors) in the reverse link
        nodeSiz = obj.theScenarioInfo.NodeSiz;
        [nodeSiz,nodeSubs] = interferingNodeVectors(bsID,f,r,nodeSiz);
        % Get number of transmit and receive antennas
        Nt = f.Node.NumTransmitAntennas;
        Nr = r.Node.NumReceiveAntennas;
    else
        % BS-to-UE or UE-to-BS link
        BS = obj.theBSMap(bsID);
        UE = obj.theUEMap(ueID);
        % Create 'nodeSiz'
        nodeSiz = obj.theScenarioInfo.NodeSiz;
        % Create 'nodeSubs'
        nodeSubs = [BS.NodeSubs(1:2) UE.NodeSubs(3)];
        % Get number of transmit and receive antennas
        if (isUplink)
            % Note that channels are in the downlink direction and operate
            % as reciprocal links for the uplink direction. Therefore, the
            % antenna counts below are for the downlink
            Nt = BS.Node.NumReceiveAntennas;
            Nr = UE.Node.NumTransmitAntennas;
        else % downlink
            Nt = BS.Node.NumTransmitAntennas;
            Nr = UE.Node.NumReceiveAntennas;
        end
    end

    % Update the scenario in the path loss configuration, in case the
    % object property has changed    
    obj.thePathLossConfig.Scenario = obj.Scenario;

    % ---------------------------------------------------------------------
    % TR 38.901 Section 7.5 Steps 2 - 10
    % Create channel from low-level parameters
    ISD = obj.theScenarioInfo.InterSiteDistance;
    chcfg = struct();
    chcfg.Seed = obj.Seed;
    chcfg.Scenario = string(obj.Scenario);
    chcfg.InterSiteDistance = ISD;
    % If site positions have changed since the last call to
    % createSLSChannelLink, or if this is the first call
    sitePositions = obj.theRecordedSitePositions;
    if (~isequal(obj.theSitePositions,sitePositions))
        % Store those positions and pass them to
        % h38901Channel.createChannelLink in order to reset
        % spatially consistent random variables (SCRVs)
        chcfg.SitePositions = sitePositions;
        obj.theSitePositions = sitePositions;
    else
        % Otherwise pass empty site positions
        chcfg.SitePositions = [];
    end
    chcfg.HasSmallScale = hasSmallScale;
    chcfg.FastFading = fastFading;
    chcfg.NodeSubs = nodeSubs;
    chcfg.NodeSiz = nodeSiz;
    if obj.InterfererSameLinkEnd
        chcfg.NumCellSites = obj.theScenarioInfo.NodeSiz(1);
    end
    chcfg.NumTransmitAntennas = Nt;
    chcfg.NumReceiveAntennas = Nr;
    if (isnan(isUplink))
        % BS-to-BS or UE-to-UE link
        chcfg.BSPosition = f.Node.Position;
        chcfg.UEPosition = r.Node.Position;
        chcfg.SampleRate = f.OFDMInfo.SampleRate;
        if (~isnan(bsID))
            % BS-to-BS link, treat receiving BS like an outdoor UE
            chcfg.TXRUVirtualization = f.TXRUVirtualization;
            chcfg.TransmitArrayOrientation = f.TransmitArrayOrientation;
            chcfg.n_fl = 0;
            chcfg.d_2D_in = 0;
            chcfg.ReceiveArrayOrientation = [];
        else
            % UE-to-UE link, treat transmitting UE like a BS with no TXRU
            % virtualization
            chcfg.TXRUVirtualization = struct(K=1,Tilt=0,L=1,Pan=0);
            chcfg.TransmitArrayOrientation = [];
            chcfg.n_fl = r.n_fl;
            chcfg.d_2D_in = r.d_2D_in;
            chcfg.ReceiveArrayOrientation = r.ReceiveArrayOrientation;
        end
    else
        % BS-to-UE or UE-to-BS link
        chcfg.SampleRate = BS.OFDMInfo.SampleRate;
        chcfg.TXRUVirtualization = BS.TXRUVirtualization;
        chcfg.TransmitArrayOrientation = BS.TransmitArrayOrientation;
        chcfg.BSPosition = BS.Node.Position;
        chcfg.UEPosition = UE.Node.Position;
        chcfg.n_fl = UE.n_fl;
        chcfg.d_2D_in = UE.d_2D_in;
        chcfg.ReceiveArrayOrientation = UE.ReceiveArrayOrientation;
    end
    chcfg.CenterFrequency = packet.CenterFrequency;
    chcfg.Wrapping = obj.theScenarioInfo.Wrapping;
    chcfg.SpatialConsistency = spatialConsistencyString(obj.theScenarioInfo.SpatialConsistency);
    chcfg.OfficeType = obj.OfficeType;
    if (~isempty(obj.ScenarioExtents))
        extents = obj.ScenarioExtents;
    else
        if (startsWith(chcfg.Scenario,"InF"))
            % Defaulted inside h38901Channel.createChannelLink from
            % chCfg.HallSize
            extents = [];
        else
            if (~isnan(ISD) && any(chcfg.Scenario==["UMi" "UMa" "RMa"]))
                % Get polygons that are the boundaries for each site
                [sitex,sitey] = h38901Channel.sitePolygon(ISD);
                % Get bounding box of the union of the site polygons
                sysx = sitePositions(:,1) + sitex;
                sysy = sitePositions(:,2) + sitey;
                minpos = [min(sysx, [], 'all'), min(sysy, [], 'all')];
                maxpos = [max(sysx, [], 'all'), max(sysy, [], 'all')];
            else % InH or no ISD
                allnodepos = [sitePositions; obj.theRecordedUEPositions];
                % Note: the bounding box around the node positions is
                % extended by 1 meter on all sides here to avoid precision
                % issues when determining if nodes lie inside the scenario
                % extents
                maxpos = max(allnodepos(:,1:2),[],1) + 1;
                minpos = min(allnodepos(:,1:2),[],1) - 1;
            end
            extents = [minpos maxpos-minpos];
        end
    end
    chcfg.ScenarioExtents = extents;
    chcfg.HallSize = obj.HallSize;
    chcfg.ClutterSize = obj.ClutterSize;
    chcfg.ClutterDensity = obj.ClutterDensity;
    chcfg.ClutterHeight = obj.ClutterHeight;
    chcfg.AbsoluteTOA = obj.AbsoluteTOA;
    chcfg.LOSProbability = obj.LOSProbability;
    chcfg.UseGPU = obj.UseGPU;
    [channel,~,obj.SCRVs] = obj.nr5g.createChannelLink(chcfg,obj.SCRVs);
    channel.SmallScale.UseGPU = chcfg.UseGPU;
    channel.LargeScale = channel.LargeScale(obj.thePathLossConfig);
    % ---------------------------------------------------------------------

    % For full PHY, construct channel filters if required (that is, if path
    % delays are non-zero, due to small scale fading and/or absolute TOA)
    if (~packet.Abstraction && ~isequal(channel.PathDelays,0))
        channel = makeChannelFilters(channel);
    end

    % Record the channel
    linkind = linkIndicesForID(obj,linkID);
    obj.theLinkToChannelMap(linkind) = channel;

    if (isnan(isUplink))
        % BS-to-BS or UE-to-UE link, treat as downlink i.e. reciprocity
        % will not be used
        isUplink = false;
    end

end

function channel = makeChannelFilters(channel)

    f = comm.ChannelFilter();
    f.SampleRate = channel.SmallScale.SampleRate;
    f.PathDelays = channel.PathDelays;
    f.NormalizeChannelOutputs = false;
    r = clone(f);
    fInfo = info(f);
    channel.PathFilters = fInfo.ChannelFilterCoefficients;
    channel.ChannelFilter = f;
    channel.ChannelFilterReciprocal = r;

end

function [nodeSiz,nodeSubs] = interferingNodeVectors(bsID,f,r,nodeSiz)

    oldSiz = nodeSiz;

    % 'nUEasSite' is the number of extra sites needed to account for all
    % UEs treated as sites
    nUEasSite = nodeSiz(3);

    % 'nBSasUE' is the number of extra UEs needed to account for all BS
    % sites and sectors treated as UEs
    nBSasUE = prod(nodeSiz(1:2));

    % Update site and UE entries in 'nodeSiz'
    nodeSiz([1 3]) = nodeSiz([1 3]) + [nUEasSite nBSasUE];

    % Create 'nodeSubs'
    if (~isnan(bsID))

        % BS-to-BS link

        % 'thisBSasUE' combines 'r' BS site and sector indices into a UE
        % index
        i = r.NodeSubs(1);
        j = r.NodeSubs(2);
        thisBSasUE = (i-1)*oldSiz(2) + j;

        % 'nodeSubs' consists of site and sector index of the 'f' BS, and
        % index of the 'r' BS treated as a UE
        nodeSubs = [f.NodeSubs(1:2) oldSiz(3)+thisBSasUE];

    else

        % UE-to-UE link

        % 'thisUEasSite' uses 'f' UE index as a site index
        thisUEasSite = f.NodeSubs(3);

        % 'nodeSubs' consists of index of the 'f' UE treated as a site,
        % sector set to 1, and the index of the 'r' UE
        nodeSubs = [oldSiz(1)+thisUEasSite 1 r.NodeSubs(3)];

    end

end

% Apply channel filtering to signal 'x' using path gains 'pg' and sample
% times 't'
function y = channelFiltering(ch,x,pg,t)

    if (~ch.SmallScale.TransmitAndReceiveSwapped)
        f = ch.ChannelFilter;
    else
        f = ch.ChannelFilterReciprocal;
    end
    fInfo = info(f);
    pathFilters = fInfo.ChannelFilterCoefficients;
    Nh = size(pathFilters,2);
    Nt = size(x,2);
    x = [x; zeros([Nh Nt])];
    insize = size(x);
    if (~isstruct(ch.SmallScale))
        sampleDensity = ch.SmallScale.SampleDensity;
    else
        sampleDensity = 1;
    end
    t = t - t(1);
    outputtype = class(x);
    % If the channel filter is not locked (i.e. hasn't yet been used)
    if (~isLocked(f))
        % Determine the best filter option for the current input
        sizg = size(pg,1:4);
        T = insize(1);
        p = wireless.internal.channelmodels.getFilterPolicy(outputtype,[sizg T]);
        % If the option is to filter waveform sections where each section
        % corresponds to a first dimension element of 'pg', configure the
        % channel filter for efficient execution of this case
        f.OptimizeScalarGainFilter = (p.FilterOption==2);
    end
    filterOption = 1 + f.OptimizeScalarGainFilter;
    y = wireless.internal.channelmodels.smartChannelFiltering(x,f,f.SampleRate,pg,insize,sampleDensity,t,outputtype,filterOption);

end

% Get BS and UE IDs for this link and establish if the link is uplink
function [bsID,ueID,isUplink] = getBSandUE(obj,linkID)

    maxBSID = obj.theScenarioInfo.MaxBSID;
    txIsUE = isKey(obj.theUEtoBSMap,linkID(1));
    if (txIsUE)
        ueID = linkID(1);
        bsID = linkID(2);
        isUplink = true;
    else
        ueID = linkID(2);
        bsID = linkID(1);
        isUplink = false;
        if (ueID <= maxBSID)
            ueID = NaN;
            isUplink = NaN;
            return;
        end
    end
    if (bsID > maxBSID)
        bsID = NaN;
        isUplink = NaN;
    end

end

% Establish if a link is between two nodes that are attached, and also
% establish the BS and UE IDs
function [c,bsID,ueID] = isAttached(obj,linkID)

    [bsID,ueID] = getBSandUE(obj,linkID);
    if (isnan(bsID) || isnan(ueID))
        % BS-to-BS or UE-to-UE link, not attached
        c = false;
    else
        c = (obj.theUEtoBSMap(ueID)==bsID);
    end

end

% Get linear index (used as a dictionary hash) from a link ID pair
function ind = linkIndicesForID(obj,linkID)

    ind = (linkID(1)-1)*obj.theScenarioInfo.MaxLinkID + linkID(2);

end

% Record list of gNBs, connections between gNBs and UEs, and other scenario
% information that can be established from the scenario builder or channel
% configuration structure
function recordNodes(obj,sls,cfg)

    % Get gNBs and UEs
    toMat = @(x)[x{:}];
    nodes = sls.Nodes;
    nodeTypes = cellfun(@class,nodes,UniformOutput=false);
    nodesOfType = @(t)toMat(nodes(strcmp(nodeTypes,t)));
    gNBs = nodesOfType('nrGNB');
    UEs = nodesOfType('nrUE');
    if (~isempty(UEs))
        ueIDs = [UEs.ID];
        UEs = cellfun(@(x)UEs(ueIndices(ueIDs,x)),{gNBs.UENodeIDs},UniformOutput=false);
    else
        ueIDs = [];
    end

    % Get scenario builder or channel configuration structure
    if (~isstruct(cfg))
        scenario = cfg;
        chCfg = [];
    else
        scenario = [];
        chCfg = cfg;
        chCfg.UEIDs = ueIDs;
    end

    noNodeWarning = @(s)warning(['nr5g:h38901Channel:No' s 'Nodes'],'No nr%s nodes have been added to the wirelessNetworkSimulator. Call h38901Channel/connectNodes after all nodes have been added to the wirelessNetworkSimulator.',s);
    if (~isempty(gNBs))
        maxBSID = max([gNBs.ID]);
        obj.theScenarioInfo.MaxBSID = maxBSID;
        obj.theScenarioInfo.NodeSiz(1) = maxBSID;
        obj.theScenarioInfo.MaxLinkID = maxBSID;
    else
        maxBSID = [];
        noNodeWarning('GNB');
    end

    if (~isempty(UEs))
        minUEID = min([cat(2,UEs{:}).ID]);
        maxUEID = max([cat(2,UEs{:}).ID]);
        if (~isempty(maxUEID))
            obj.theScenarioInfo.NodeSiz(3) = maxUEID;
        end
    else
        minUEID = [];
        noNodeWarning('UE');
    end

    if (~isempty(maxBSID) && ~isempty(minUEID))
        if (minUEID < maxBSID)
            error('nr5g:h38901Channel:UENodeFirst','The minimum UE ID (%d) is less than maximum gNB ID (%d). Create all gNB nodes before creating any UE nodes, to ensure that all UE IDs are greater than all gNB IDs.',minUEID,maxBSID);
        end
    end

    obj.theScenarioInfo.SpatialConsistency = obj.SpatialConsistency;

    chCfgSpecified = ~isempty(chCfg);

    if (chCfgSpecified)
        if (isfield(chCfg,"TransmitArrayOrientation"))
            [~,~,ic] = unique(chCfg.TransmitArrayOrientation.','rows');
            chCfg.Sector = ic.';
        end
        if (~any(string(obj.Scenario)==["UMi" "UMa" "RMa"]))
            for field = ["d_2D_in" "n_fl"]
                if (isfield(chCfg,field))
                    chCfg = rmfield(chCfg,field);
                end
            end
        end
    end

    scenarioSpecified = ~isempty(scenario);

    if (~scenarioSpecified)
        nodeinfo = [];
    end

    firstUE = true;
    for i = 1:numel(gNBs)

        bs = gNBs(i);
        site = getFieldColumnOrDefault(chCfg,"Site",i,bs.ID);
        sector = getFieldColumnOrDefault(chCfg,"Sector",i,1);

        if (scenarioSpecified)
            nodeinfo = dropConditions(scenario,bs);
        end
        if (~isempty(nodeinfo))
            subs = nodeinfo.NodeSubs;
        else
            subs = [site sector];
        end
        ofdmInfo = nrOFDMInfo(bs.NumResourceBlocks,bs.SubcarrierSpacing/1e3);

        virt = getFieldColumnOrDefault(chCfg,"TXRUVirtualization",i,struct(K=1,Tilt=0,L=1,Pan=0));
        txorientation = getFieldColumnOrDefault(chCfg,"TransmitArrayOrientation",i,[]);
        obj.theBSMap(bs.ID) = struct(Node=bs,NodeSubs=subs,OFDMInfo=ofdmInfo,TXRUVirtualization=virt,TransmitArrayOrientation=txorientation);

        for j = 1:numel(UEs{i})

            ue = UEs{i}(j);

            if (scenarioSpecified)
                nodeinfo = dropConditions(scenario,ue);
            end
            if (isCellular(obj.Scenario) && ~isempty(nodeinfo))
                subs = nodeinfo.NodeSubs;
                siz = nodeinfo.NodeSiz;
                if (firstUE)
                    obj.theScenarioInfo.InterSiteDistance = scenario.InterSiteDistance;
                    obj.theScenarioInfo.Wrapping = scenario.Wrapping;
                    obj.theScenarioInfo.SpatialConsistency = scenario.SpatialConsistency;
                    obj.theScenarioInfo.NodeSiz = siz;
                else
                    obj.theScenarioInfo.NodeSiz = max([obj.theScenarioInfo.NodeSiz; subs],[],1);
                end
                n_fl = nodeinfo.n_fl;
                d_2D_in = nodeinfo.d_2D_in;
                rxorientation = [];
            else
                if (chCfgSpecified)
                    subs = [site sector j];
                else
                    subs = [site sector ue.ID];
                end
                if (chCfgSpecified && firstUE)
                    obj.theScenarioInfo.InterSiteDistance = obj.InterSiteDistance;
                    obj.theScenarioInfo.Wrapping = obj.Wrapping;
                    siz = [max(chCfg.Site) max(chCfg.Sector) max(cellfun(@numel,UEs))];
                    obj.theScenarioInfo.NodeSiz = siz;
                end
                obj.theScenarioInfo.NodeSiz = max([obj.theScenarioInfo.NodeSiz; subs],[],1);
                if (chCfgSpecified)
                    default_n_fl = round((ue.Position(3)-1.5)/3 + 1);
                    el = find(chCfg.UEIDs==ue.ID,1,'first');
                else
                    default_n_fl = 0;
                    el = [];
                end
                n_fl = getFieldColumnOrDefault(chCfg,"n_fl",el,default_n_fl);
                d_2D_in = getFieldColumnOrDefault(chCfg,"d_2D_in",el,0);
                rxorientation = getFieldColumnOrDefault(chCfg,"ReceiveArrayOrientation",el,[]);
            end

            firstUE = false;

            obj.theUEMap(ue.ID) = struct(Node=ue,NodeSubs=subs,OFDMInfo=ofdmInfo,n_fl=n_fl,d_2D_in=d_2D_in,ReceiveArrayOrientation=rxorientation);
            obj.theScenarioInfo.MaxLinkID = max([obj.theScenarioInfo.MaxLinkID ue.ID]);

            obj.theUEtoBSMap(ue.ID) = bs.ID;

        end

    end

    obj.theRecordedSitePositions = getNodePositions(obj.theBSMap);
    obj.theRecordedUEPositions = getNodePositions(obj.theUEMap);

end

function ind = ueIndices(ueIDs,x)

    if (isempty(x))
        ind = [];
    else
        ind = any(ueIDs==x.',1);
    end

end

function p = getNodePositions(m)

    v = values(m);
    if (~isempty(v))
        p = cat(1,cat(1,v.Node).Position);
    else
        p = zeros(0,3);
    end

end

function v = getFieldColumnOrDefault(s,f,i,d)

    if (isfield(s,f))
        v = s.(f);
        if (size(v,2) > 1)
            v = v(:,i);
        end
    else
        v = d;
    end

end

function ch = packetMobilitySLS(obj,ch,packet,rxinfo)

    % Set up mobility configuration structure from object properties
    cfg.SpatialConsistency = spatialConsistencyString(obj.SpatialConsistency);
    cfg.UpdateDistance = obj.UpdateDistance;

    % Get input time, equal to packet start time
    t = packet.StartTime;

    % Set up transmitter info structure from transmitted packet in SLS
    tx = struct();
    tx.Position = packet.TransmitterPosition;
    tx.Velocity = packet.TransmitterVelocity;

    % Set up receiver info structure from receiver info in SLS
    rx = struct();
    rx.Position = rxinfo.Position;
    rx.Velocity = rxinfo.Velocity;

    % SLS does not provide rotation information. The rotation velocity is
    % set to zero. The current direction of travel is stored. The array
    % orientations will be updated after the mobility update in order to
    % keep the antenna array orientations fixed relative to the direction
    % of travel
    tx.RotationVelocity = [0; 0; 0];
    rx.RotationVelocity = [0; 0; 0];
    old_direction = ch.Mobility.UTDirectionOfTravel;

    % Perform mobility update
    if (isempty(ch.Mobility.manager))
        ch.Mobility.manager = obj.nr5g.mobilityManager(obj.SCRVs,cfg);
    end
    chSpatialConsistency = ch.ChannelConfiguration.SpatialConsistency;
    if (~strcmpi(chSpatialConsistency,cfg.SpatialConsistency))
        error('nr5g:h38901Channel:ChangedSpatialConsistencySLS','Spatial consistency configured when initially dropping UEs, h38901Scenario.SpatialConsistency (%s), must match SpatialConsistency configured in h38901Channel (%s).',chSpatialConsistency,cfg.SpatialConsistency);
    end
    [ch,updated] = ch.Mobility.manager.update(ch,t,tx,rx);

    % Update antenna array orientations in order to keep them fixed
    % relative to the direction of travel
    if (updated)
        ch = updateArrayOrientations(ch,old_direction);
    end

    % Update channel filters in case path delays have changed
    if (updated && ~packet.Abstraction)
        ch = makeChannelFilters(ch);
    end

end

function ch = updateArrayOrientations(ch,old_direction)

    ss = ch.SmallScale;

    delta_direction = ch.Mobility.UTDirectionOfTravel - old_direction;

    delta_direction_rx = delta_direction(:,1);
    ss.ReceiveArrayOrientation = updateArrayOrientation(ss.ReceiveArrayOrientation,delta_direction_rx);

    delta_direction_tx = delta_direction(:,2);
    ss.TransmitArrayOrientation = updateArrayOrientation(ss.TransmitArrayOrientation,delta_direction_tx);

    ch.SmallScale = ss;

end

function ao = updateArrayOrientation(ao,delta_azel)

    % The bearing angle of the array is updated by the change in azimuth
    % angle of the direction of travel
    delta_phi = delta_azel(1);
    ao(1) = ao(1) + delta_phi;

    % The downtilt angle of the array is updated by the change in elevation
    % angle of the direction of travel
    delta_theta = delta_azel(2);
    ao(2) = ao(2) + delta_theta;

end

%% ========================================================================
%  local functions independent of wirelessNetworkSimulator
%  ========================================================================

% Set object properties from name-value arguments
function setProperties(obj,varargin)

    for i = 1:2:(nargin-1)
        n = varargin{i};
        v = varargin{i+1};
        obj.(n) = v;
    end

end

%% ========================================================================

function [pathGains,sampleTimes] = spanSlot(obj,bsID,ueID,pathGains,sampleTimes)

    if (~isscalar(sampleTimes))

        % Get OFDM information and calculate sample time Ts
        if (~isnan(bsID))
            node = obj.theBSMap(bsID);
        else
            node = obj.theUEMap(ueID);
        end
        ofdmInfo = node.OFDMInfo;
        Ts = 1 / ofdmInfo.SampleRate;

        % Calculate the whole number of subframes elapsed up to the start
        % of the packet, and the corresponding number of samples
        wholeSubframes = floor((sampleTimes(1)+Ts) / 1e-3);
        samplesPerSubframe = 1e-3 / Ts;
        wholeSubframeSamples = wholeSubframes * samplesPerSubframe;

        % Calculate the start and end sample index of each slot of the
        % subframe
        samplesPerSlot = sum(reshape(ofdmInfo.SymbolLengths,ofdmInfo.SymbolsPerSlot,[]),1);
        slotStartSamples = wholeSubframeSamples + cumsum([0 samplesPerSlot(1:end-1)]);
        slotEndSamples = slotStartSamples + samplesPerSlot;

        % Get the start and end sample index of the packet
        packetStartSample = sampleTimes(1) / Ts;
        packetEndSample = sampleTimes(end) / Ts;

        % Find the start and end sample index of the slot which contains
        % the packet
        deltaStart = abs(packetStartSample - slotStartSamples);
        deltaEnd = abs(packetEndSample - slotEndSamples);
        [deltaStart_min,slotIdxStart] = min(deltaStart);
        [deltaEnd_min,slotIdxEnd] = min(deltaEnd);
        if (deltaStart_min < deltaEnd_min)
            slotIdx = slotIdxStart;
        else
            slotIdx = slotIdxEnd;
        end
        slotStartSample = slotStartSamples(slotIdx);
        slotEndSample = slotEndSamples(slotIdx);

        % Extend the path gains and sample times if they do not encompass
        % the start or end of the slot
        if (packetStartSample > slotStartSample)
            slotStartTime = slotStartSample * Ts;
            if (slotStartTime~=sampleTimes(1))
                sampleTimes = [slotStartTime; sampleTimes];
                pathGains = [pathGains(1,:,:,:); pathGains];
            end
        end
        if (packetEndSample < slotEndSample)
            slotEndTime = slotEndSample * Ts;
            if (slotEndTime~=sampleTimes(end))
                sampleTimes = [sampleTimes; slotEndTime];
                pathGains = [pathGains; pathGains(end,:,:,:)];
            end
        end

    end

end

function y = isCellular(s)

    y = any(s==["UMi","UMa","RMa"]);

end

function y = isSpatiallyConsistentMobility(s)

    sc = spatialConsistencyString(s.SpatialConsistency);
    y = any(strcmpi(sc,["ProcedureA" "ProcedureB"]));

end

function sc = spatialConsistencyString(osc)

    if (isnumeric(osc) || islogical(osc))
        if (osc)
            sc = "Static";
        else
            sc = "None";
        end
    else
        sc = string(osc);
    end

end

function out = manageSCRVs(varargin)

    persistent SCRVs;
    if (nargin==1)
        SCRVs = varargin{1};
    end
    out = SCRVs;

end

function validateScenarioExtents(val)

    if (~isempty(val))
        if (~isrow(val) || ~(numel(val)==4))
            error('nr5g:h38901Channel:InvalidScenarioExtents','Value must be empty or be a 4-element row vector [left bottom width height].');
        end
    end

end

function validateSpatialConsistency(val)

    if (~isnumeric(val) && ~islogical(val))
        mustBeTextScalar(val);
        matlab.system.mustBeMember(val, ...
            ["None" "Static" "ProcedureA" "ProcedureB"]);
    end

end
