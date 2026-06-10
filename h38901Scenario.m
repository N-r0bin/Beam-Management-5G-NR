classdef h38901Scenario < handle
%h38901Scenario TR 38.901 system-level scenario builder
%
%   h38901Scenario properties:
%
%   Scenario           - Deployment scenario ("UMi", "UMa", "RMa")
%                        (default "UMa")
%   CarrierFrequency   - Carrier frequency in Hz (default 6e9)
%   InterSiteDistance  - Intersite distance in meters (default 500)
%   NumCellSites       - Number of cell sites (1...19) (default 19)
%   NumSectors         - Number of sectors per cell site (1, 3) (default 3)
%   NumUEs             - Number of UEs to drop per cell (default 10)
%   ChosenUEs          - UE dropping method (false, true) (default true)
%   Wrapping           - Geographical distance-based wrapping (true, false)
%                        (default true)
%   SpatialConsistency - Spatial consistency ("None", "Static", 
%                        "ProcedureA", "ProcedureB") (default "None")
%   FullBufferTraffic  - Traffic configuration ("DL", "UL", "on", "off")
%                        (default "DL")
%   Seed               - Random number generator (RNG) seed (default 0)
%   IndoorRatio        - Indoor UE ratio (default [])
%
%   h38901Scenario properties (read-only):
%
%   CellSites          - Structure array containing nrGNBs and nrUEs
%   ScenarioExtents    - Location and size of the scenario
%   
%   h38901Scenario object functions:
%
%   h38901Scenario     - Create scenario builder
%   configureSimulator - Create sites, sectors, and UEs for scenario
%   addCellSite        - Add a cell site at a specific position
%   dropUEs            - Drop UEs randomly across the system
%   addUEs             - Add UEs to a specific site and sector
%   createChannelLinks - Create the set of channel links for a scenario
%   dropConditions     - Information for a node dropped in the scenario
%
%   See also h38901Channel, wirelessNetworkSimulator, nrGNB, nrUE.

%   Copyright 2022-2026 The MathWorks, Inc.

    % =====================================================================
    % public interface

    properties (SetAccess=private)

        % Deployment scenario to determine properties of nrGNBs and nrUEs
        % created in the configureSimulator object function ("UMi", "UMa",
        % "RMa") (default "UMa")
        Scenario (1,1) string ...
            {matlab.system.mustBeMember(Scenario,["UMi" "UMa" "RMa"])} ...
            = "UMa";

        % Carrier frequency in Hz (default 6e9)
        CarrierFrequency (1,1) double ...
            {mustBeReal, mustBeNonnegative, mustBeFinite} ...
            = 6e9;

        % Intersite distance in meters (default 500)
        InterSiteDistance (1,1) double ...
            {mustBeReal, mustBePositive, mustBeFinite} ...
            = 500;

        % Number of cell sites (1...19) (default 19)
        NumCellSites (1,1) double ...
            {mustBeReal, mustBePositive, mustBeInteger} ...
            = 19;

        % Number of sectorized gNBs per cell site (1,3) (default 3). For
        % NumSectors=1, there is one gNB per cell site with no
        % sectorization and isotropic antenna elements. For NumSectors=3,
        % there are three gNBs per cell site with boresight azimuth angles
        % of 30, 150, and -90 degrees and antenna elements according to TR
        % 38.901 Table 7.3-1
        NumSectors (1,1) double ...
            {mustBeReal, mustBePositive, mustBeInteger} ...
            = 3;

        % Number of UEs to drop per cell. If ChosenUEs=false, NumUEs
        % specifies the average number. If ChosenUEs=true, NumUEs specifies
        % the exact number (default 10)
        NumUEs (1,1) double ...
            {mustBeReal, mustBePositive, mustBeInteger} ...
            = 10;

        % Set ChosenUEs=true to select a number of "chosen" UEs, as
        % described in Rec. ITU-R M.2101-0 Section 3.4.1. The NumUEs
        % property specifies the number of UEs. If ChosenUEs=false, the
        % NumUEs property specifies the average number of UEs per cell i.e.
        % NumCellSites * 3 * NumUEs are dropped across the system in total
        ChosenUEs (1,1) ...
            {mustBeNumericOrLogical} ...
            = true;

        % Enable wrap around calculations, as defined in Rec. ITU-R
        % M.2101-0 Attachment 2 to Annex 1
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

        % Traffic configuration when connecting nrUEs to an nrGNB during
        % scenario building ("DL", "UL", "on", "off") (default "DL")
        FullBufferTraffic (1,1) string ...
            {matlab.system.mustBeMember(FullBufferTraffic, ...
            ["DL" "UL" "on" "off"])} ...
            = "DL";

        % Random number generator seed (default 0)
        Seed (1,1) double ...
            {mustBeReal, mustBeInteger, mustBeNonnegative} ...
            = 0;

        % Indoor UE ratio. A scalar between 0 and 1 giving the probability
        % that a randomly-dropped UE will be indoor. If empty, the indoor
        % UE ratio is determined using TR 38.901 Tables 7.2-1 and 7.2-3
        % (default [])
        IndoorRatio double ...
            {mustBeScalarOrEmpty, mustBeBetween(IndoorRatio,0,1)} ...
            = [];

    end

    properties (SetAccess=private)

        % 1-by-NumCellSites structure array with each element 
        % corresponding to a cell site. Each element has the field:
        %
        % Sectors - 1-by-NumSectors structure array with each element
        %           corresponding to a sector. Each element has the fields:
        %
        %           BS  - The nrGNB node representing the base station
        %           UEs - A 1-by-N array of nrUE nodes, representing the 
        %                 UEs attached to the BS. The number of UEs N 
        %                 depends on the UE dropping method (ChosenUEs)
        CellSites;

        % Location and size of the scenario, a four-element vector of the
        % form [left bottom width height]. The elements are defined as 
        % follows:
        %   left   - The X coordinate of the left edge of the scenario in 
        %            meters
        %   bottom - The Y coordinate of the bottom edge of the scenario in 
        %            meters
        %   width  - The width of the scenario in meters, that is, the 
        %            right edge of the scenario is left + width
        %   height - The height of the scenario in meters, that is, the 
        %            top edge of the scenario is bottom + height
        ScenarioExtents;

    end

    methods (Access=public)

        function scenario = h38901Scenario(varargin)
        % Create scenario builder

            % Set properties from name-value arguments
            setProperties(scenario,varargin{:});

            % Set up path loss configuration
            scenario.thePathLossConfig = nrPathLossConfig(Scenario=scenario.Scenario);

            % Initialize RNG
            scenario.theRandStream = RandStream('mt19937ar','Seed',scenario.Seed);

            % Initialize TR 38.901 definitions
            scenario.nr5g = nr5g.internal.channel38901;

            % Create site positions
            scenario.theSitePositions = scenario.nr5g.createSitePositions(scenario.InterSiteDistance);

            % Create empty auto-correlation matrices
            scenario.theAutoCorrMatrices = [];
            scenario.theFirstCoord = [];

            % Initialize count of UEs dropped
            scenario.theUECount = 0;

            % Create map between IDs and UEs
            scenario.theUEMap = dictionary([],struct());

            % Create map between IDs and BSs
            scenario.theBSMap = dictionary([],struct());

            % Create SCRVs
            scenario.SCRVs = [];

        end

        function configureSimulator(scenario,sls)
        % configureSimulator(SCENARIO,SLS) creates cell sites, sectors, BS
        % nodes, and UE nodes according to the scenario, attaches UEs to
        % BSs (including specifying traffic configuration), and attaches
        % all nodes to the wirelessNetworkSimulator object, SLS

            % For each cell site
            numCellSites = scenario.NumCellSites;
            for i = 1:numCellSites

                % Create the cell site (with sectorized cells)
                addCellSite(scenario,sls,NumTransmitAntennas=1,NumReceiveAntennas=1,DuplexMode='TDD',TransmitPower=txPower(scenario),ReceiveGain=6,CarrierFrequency=scenario.CarrierFrequency,ChannelBandwidth=cbw(scenario),SubcarrierSpacing=scs(scenario));

            end

            % Drop UEs and connect them to the cells
            dropUEs(scenario,sls,NumTransmitAntennas=1,NumReceiveAntennas=1,NoiseFigure=9,ReceiveGain=0);

        end

        function BSs = addCellSite(scenario,sls,varargin)
        % BSs = addCellSite(SCENARIO,SLS) adds a cell site to the system.
        % The position of the site is the next uninitialized site in the
        % system layout. The function creates an nrGNB object for each
        % sector at the same position.
        %
        % BSs = addCellSite(SCENARIO,SLS,Name=Value) specifies additional 
        % name-value arguments described below.
        %
        % Position - A row vector containing three numeric values 
        %            representing the [X, Y, Z] position of the site in
        %            meters. The default is to use the next uninitialized
        %            site in the system layout.
        %
        % In addition, you can specify any nrGNB object property as a
        % name-value argument to initialize the nrGNB objects that the
        % function creates when adding the cell site to the system.

            % Create cell site
            cellSite = createCellSite(scenario,varargin{:});

            % Record cell site here
            sitesub = recordCellSite(scenario,cellSite);

            % Add the cell site to the wirelessNetworkSimulator
            BSs = cat(2,cellSite.Sectors.BS);
            addNodes(sls,BSs);

            % Record gNB drop information
            recordBSDrop(scenario,sitesub);

        end

        function UEs = dropUEs(scenario,sls,varargin)
        % UEs = dropUEs(SCENARIO,SLS) drops UEs randomly across the system
        % and attaches the UEs to BSs by path loss. The function attaches
        % the UE nodes to the wirelessNetworkSimulator object, SLS.
        %
        % UEs = dropUEs(SCENARIO,SLS,Name=Value) specifies additional
        % name-value arguments described below.
        %
        % TXRUVirtualization   - Structure specifying the parameters for 
        %                        TR 36.897 Section 5.2.2 TXRU 
        %                        virtualization model option-1B. The
        %                        structure has the following fields:
        %                           K    - Vertical weight vector length
        %                           Tilt - Tilting angle in degrees
        %                           L    - Horizontal weight vector length
        %                           Pan  - Panning angle in degrees
        %                        The default value is 
        %                        struct(K=1,Tilt=0,L=1,Pan=0).
        % DropMode             - Specified as 'CouplingLoss' or 'PathLoss'.
        %                        Specifies whether UEs are attached to the
        %                        BS with the maximum coupling loss or path
        %                        loss during UE dropping. For 'PathLoss',
        %                        the LOS angle between the site and the UE
        %                        is used to determine the sector. The
        %                        default value is 'PathLoss'.
        % TransmitAntennaArray - Structure specifying the transmit antenna 
        %                        array characteristics, see 
        %                        nrCDLChannel/TransmitAntennaArray
        %                        for details.
        % ReceiveAntennaArray  - Structure specifying the receive antenna 
        %                        array characteristics, see 
        %                        nrCDLChannel/ReceiveAntennaArray
        %                        for details.
        % LOSProbability       - A scalar between 0 and 1 giving the 
        %                        probability that a randomly-dropped UE 
        %                        will be in line of sight (LOS) condition. 
        %                        If empty, the LOS probability is 
        %                        determined using TR 38.901 Table 7.4.2-1.
        %                        The default value is [].
        %
        % In addition, you can specify any nrUE object property as a
        % name-value argument to initialize the dropped UE nodes.

            % Create UEs by dropping UEs randomly across the system and
            % attaching to BSs by coupling loss or path loss
            [UEs,sites,sectors,dropinfo] = createUEs(scenario,varargin{:});

            % Record UEs here
            recordUEs(scenario,UEs,sites,sectors);

            % Connect UEs to their respective BSs and add UEs to the 
            % wirelessNetworkSimulator object
            connectUEs(scenario,UEs,sites,sectors);
            addNodes(sls,UEs);

            % Record UE drop information
            scenario.theUEMap([UEs.ID]) = dropinfo;

        end

        function UEs = addUEs(scenario,sls,UEs,varargin)
        % UEs = addUEs(SCENARIO,SLS,UEs,Name=Value) adds UEs to a specific
        % site and sector, connects the UEs to the BS for that sector, and
        % connect the UEs to the wirelessNetworkSimulator object, SLS. The
        % following name-value arguments must be specified:
        % 
        % Site   - A scalar integer (1...OBJ.NumCellSites) specifying the 
        %          site in which to add the UEs, or a vector of integers 
        %          specifying the site in which to add each UE.
        % Sector - A scalar integer (1...OBJ.NumSectors) specifying the 
        %          sector in which to add the UEs, or a vector of integers 
        %          specifying the sector in which to add each UE.

            % Determine site and sector
            opts = parseInputs(struct(),varargin{:});
            site = opts.Site;
            sector = opts.Sector;

            % Record UE here
            if (~isscalar(UEs) && isscalar(site))
                site = repmat(site,size(UEs));
            end
            if (~isscalar(UEs) && isscalar(sector))
                sector = repmat(sector,size(UEs));
            end
            recordUEs(scenario,UEs,site,sector);

            % Connect UE to its BS and add UE to the
            % wirelessNetworkSimulator
            connectUEs(scenario,UEs,site,sector);
            addNodes(sls,UEs);

            % Record UE drop information for these added UEs. Note that
            % d_2D_in and n_fl will be zero
            recordAddedUEDrop(scenario,UEs,site,sector);

        end

        function [channels,chinfo] = createChannelLinks(obj,varargin)
        % [CHANNELS,CHINFO] = createChannelLinks(SCENARIO,Name=Value)
        % creates the set of channel links, CHANNELS, for a scenario. This
        % object function implements scenario-specific aspects (3-D node
        % positions and 2-D indoor distance for UEs). It uses
        % h38901Channel/createChannelLink to create the individual channel
        % links.
        % 
        % CHANNELS is a structure array with each element specifying a
        % BS-UE channel link. The structure has the following fields:
        % CenterFrequency     - The center frequency of the link in Hz.
        % NumTransmitAntennas - The number of transmit antennas at the BS. 
        % NumReceiveAntennas  - The number of receive antennas at the UE.
        % LargeScale          - The large scale part of the channel. If
        %                       EvaluatePathLoss=true (see name-value
        %                       argument below), it is a scalar specifying
        %                       the power gain in dB resulting from path
        %                       loss, O2I penetration loss and shadow
        %                       fading. Note that the value is negative -
        %                       it is described as a gain, but its value
        %                       will always represent a loss. If
        %                       EvaluatePathLoss=false, it is a function
        %                       handle which accepts node positions and
        %                       calculates the path loss for those
        %                       positions.
        % SmallScale          - The small scale part of the channel, an 
        %                       nrCDLChannel if FastFading=true (see
        %                       name-value argument below) or a structure
        %                       if FastFading=false.
        % TXRUVirtualization  - Structure specifying the parameters for
        %                       TR 36.897 Section 5.2.2 TXRU
        %                       virtualization model option-1B (see
        %                       name-value argument below)
        % PathFilters         - Channel path filter impulse responses, a
        %                       matrix of size Np-by-Nh where Np is the 
        %                       number of paths and Nh is the number of 
        %                       impulse response samples.
        % NodSubs             - A 3-element row vector specifying the site,
        %                       sector and UE subscripts for this link. 
        % NodeSiz             - A 3-element row vector specifying the total
        %                       number of sites, sectors and UEs across all
        %                       links.
        %
        % CHINFO is a structure containing the following fields:
        % AttachedUEInfo      - A structure array with detailed link 
        %                       information for each attached BS-UE link.
        % AllUEInfo           - A structure array with detailed link 
        %                       information for every BS-UE link considered
        %                       during attachment. 
        %
        % The following name-value argument must be specified:
        %
        % SampleRate           - The sample rate of the channel, see
        %                        nrCDLChannel/SampleRate for details.  
        %
        % Additional optional name-value arguments are described below.
        %
        % TXRUVirtualization   - Structure specifying the parameters for 
        %                        TR 36.897 Section 5.2.2 TXRU 
        %                        virtualization model option-1B. The
        %                        structure has the following fields:
        %                           K    - Vertical weight vector length
        %                           Tilt - Tilting angle in degrees
        %                           L    - Horizontal weight vector length
        %                           Pan  - Panning angle in degrees
        %                        The default value is 
        %                        struct(K=1,Tilt=0,L=1,Pan=0).
        % DropMode             - Specified as 'CouplingLoss' or 'PathLoss'.
        %                        Specifies whether UEs are attached to the
        %                        BS with the maximum coupling loss or path
        %                        loss during UE dropping. For 'PathLoss',
        %                        the LOS angle between the site and the UE
        %                        is used to determine the sector. The
        %                        default value is 'PathLoss'.
        % TransmitAntennaArray - Structure specifying the transmit antenna 
        %                        array characteristics, see 
        %                        nrCDLChannel/TransmitAntennaArray
        %                        for details. The default is to create the
        %                        array based on the value of the
        %                        NumTransmitAntennas name-value argument
        %                        and the number of sectors.
        % ReceiveAntennaArray  - Structure specifying the receive antenna 
        %                        array characteristics, see 
        %                        nrCDLChannel/ReceiveAntennaArray
        %                        for details. The default is to create the
        %                        array based on the value of the
        %                        NumReceiveAntennas name-value argument.
        % NumTransmitAntennas  - The number of transmit antennas at the BS.
        %                        The default value is 1.
        % NumReceiveAntennas   - The number of receive antennas at the UE.
        %                        The default value is 1.
        % FastFading           - If true, the channel links are created
        %                        with the fast fading model specified in TR
        %                        38.901 Section 7.5 steps 2 - 11. If false,
        %                        only the LOS part of the channel is
        %                        created, sufficient for calculating
        %                        coupling loss. Specifically, steps 4 - 10
        %                        are omitted and a subset of the
        %                        calculations in Step 11 are performed.
        %                        The default value is true.
        % CouplingLossInfo     - If true, the CHINFO structure will include
        %                        the coupling loss for each BS-UE link. If
        %                        false, CHINFO will include the coupling 
        %                        loss only if DropMode='CouplingLoss'. The
        %                        default value is false.
        % EvaluatePathLoss     - If true, the path loss is evaluated for
        %                        the specified node positions and returned
        %                        as a power in dB. If false, the path loss
        %                        is returned as a function handle which
        %                        accepts node positions and calculates the
        %                        path loss for those positions. The default
        %                        value is true.
        % Site                 - Restrict UE dropping to the specified
        %                        site, which must be in the range
        %                        1...NumCellSites. If absent or empty, all
        %                        sites are considered during UE dropping.
        % Sector               - Restrict UE dropping to the specified
        %                        sector, which must be in the range
        %                        1...NumSectors. If absent or empty, all
        %                        sectors are considered during UE dropping.
        % LOSProbability       - A scalar between 0 and 1 giving the 
        %                        probability that a randomly-dropped UE 
        %                        will be in line of sight (LOS) condition. 
        %                        If empty, the LOS probability is 
        %                        determined using TR 38.901 Table 7.4.2-1.
        %                        The default value is [].

            dropCfg = makeChannelLinksConfig(obj);
            h_BS = obj.nr5g.bsHeight(obj.Scenario);
            allsitepos = arrayfun(@(x)bsPositions(obj,x,h_BS),(1:obj.NumCellSites).','UniformOutput',false);
            dropCfg.SitePositions = cat(1,allsitepos{:});

            state = makeChannelLinksState(obj);
            args = validateChannelLinksArgs(varargin{:});
            [channels,chinfo,state] = obj.nr5g.createChannelLinks(dropCfg,state,args{:});
            storeChannelLinksState(obj,state);

        end

        function nodeinfo = dropConditions(obj,node)
        % NODEINFO = dropConditions(SCENARIO,NODE) provides information
        % about the parameters used when the node NODE (an nrGNB or nrUE)
        % was dropped in the scenario using the configureSimulator, 
        % addCellSite, dropUEs, or addUEs object functions.
        %
        % If NODE is an nrGNB, NODEINFO is a structure containing the
        % following fields:
        %   NodeSubs - A 2-element row vector specifying the site and 
        %              sector subscripts for this gNB. 
        %   NodeSiz  - A 2-element row vector specifying the total number
        %              of sites and sectors across all gNBs.
        % 
        % If NODE is an nrUE, NODEINFO is a structure containing the
        % following fields:
        %   NodeSubs - A 3-element row vector specifying the site, sector 
        %              and UE subscripts for this UE. 
        %   NodeSiz  - A 3-element row vector specifying the total number 
        %              of sites, sectors and UEs across all UEs.
        %   n_fl     - The 1-based floor number of the UE 
        %              (1 = ground floor).
        %   d_2D_in  - The 2-D indoor distance for the UE in meters.
        %
        % If NODE is an nrGNB or nrUE not created by the
        % configureSimulator, addCellSite, or dropUEs object functions,
        % NODEINFO is empty. If NODE is an nrUE added to the scenario by
        % the addUEs object function, the n_fl and d_2D_in fields of
        % NODEINFO will be zero.

            if (isa(node,'nrGNB'))
                m = obj.theBSMap;
            else % nrUE
                m = obj.theUEMap;
            end
            if (isKey(m,node.ID))
                nodeinfo = m(node.ID);
            else
                nodeinfo = [];
            end

        end

    end

    methods

        function v = get.ScenarioExtents(scenario)

            % Ensure that cell sites are initialized
            initializeCellSites(scenario);

            % Get sites
            gNBs = cat(2,cat(2,scenario.CellSites.Sectors).BS);
            if (~isempty(gNBs))
                sites = cat(1,gNBs.Position);
                sites = sites(:,1:2);
            else
                sites = zeros(0,2);
            end

            % Get extents
            v = getScenarioExtents(scenario,sites);

        end

    end

    % =====================================================================
    % private

    properties (SetAccess=private,Hidden)

        ChannelInfo;

    end

    properties (Dependent,SetAccess=private,Hidden)

        ChannelLinksState;
        ChannelLinksConfig;

    end

    methods

        function val = get.ChannelLinksState(obj)

            val = makeChannelLinksState(obj);

        end

        function val = get.ChannelLinksConfig(obj)

            val = makeChannelLinksConfig(obj);

        end

    end

    properties (Access=private)

        theCellSiteCursor;
        theSitePositions;
        thePathLossConfig;
        theRandStream;
        theAutoCorrMatrices;
        theFirstCoord;
        theUECount;
        theUEMap;
        theBSMap;
        nr5g;
        SCRVs;

    end

end

%% ========================================================================
%  local functions related to wirelessNetworkSimulator
%  ========================================================================

% Create a cell site
function cellSite = createCellSite(obj,varargin)

    % Ensure that cell sites are initialized
    initializeCellSites(obj);

    % Configure options from name-value arguments
    opts = parseInputs(struct(),varargin{:});

    % Create nrGNBs corresponding to BSs in this site. The site index and
    % sector index of each nrGNB are stored and later accessed by
    % h38901Channel to calculate channel parameters when a channel link for
    % these nodes is requested by wirelessNetworkSimulator
    numCellSites = obj.NumCellSites;
    numSectors = obj.NumSectors;
    h_BS = obj.nr5g.bsHeight(obj.Scenario);
    h_BS = repmat(h_BS,numSectors,1);
    args = varargin;
    if (isfield(opts,'Position'))
        pos = repmat(opts.Position,numSectors,1);
        posidx = find(cellfun(@(x)isequal(x,'Position'),args));
        args(posidx:posidx+1) = [];
    else
        pos = bsPositions(obj,obj.theCellSiteCursor,h_BS);
    end

    if (isfield(opts,'CarrierFrequency'))
        fcidx = find(cellfun(@(x)isequal(x,'CarrierFrequency'),args));
        fcarg = args{fcidx+1};
        if (fcarg~=obj.CarrierFrequency)
            warning('nr5g:h38901Scenario:CarrierFrequencyIgnored','The CarrierFrequency passed to addCellSite (%g GHz) is not equal to the CarrierFrequency property (%g GHz) and is ignored.',fcarg/1e9,obj.CarrierFrequency/1e9);
            args{fcidx+1} = obj.CarrierFrequency;
        end
    end

    if isfield(opts, 'SubcarrierSpacing')
        subcarrierSpacing = opts.SubcarrierSpacing;
    else
        subcarrierSpacing = scs(obj);
        args = [args 'SubcarrierSpacing' subcarrierSpacing];
    end

    % Calculate the SRS resource periodicity based on TDD DL-UL
    % configuration if present; otherwise, use the default value (5).
    srsResourcePeriodicity = 5; % (slots)

    if isfield(opts, 'DuplexMode') && strcmpi(opts.DuplexMode, 'TDD') && isfield(opts, 'DLULConfigTDD')
        % Validate the DLULConfigTDD
        validateDLULTDDConfig(opts.DLULConfigTDD, subcarrierSpacing);
        srsResourcePeriodicity = calculateSRSResourcePeriodicity(opts.DLULConfigTDD, subcarrierSpacing);
    end

    % Calculate the maximum number of connected UEs
    if (obj.ChosenUEs)
        % With ChosenUEs=true, every site and sector has the same number of
        % UEs, so maximum connected UEs is equal to NumUEs
        maxUE = obj.NumUEs;
    else
        % With ChosenUEs=false, different sites and sectors likely have
        % different numbers of UEs. 'maxUE' is taken to be the same as total
        % number of UEs, because in worst (but extremely unlikely) case all UEs 
        % may be attached to the same site and sector
        maxUE = numCellSites*numSectors*obj.NumUEs;
    end

    % Validate custom SRS transmit periodicity if provided; otherwise, 
    % compute it based on resource periodicity and number of connected UEs
    if isfield(opts, 'SRSPeriodicityUE')
        srsTransmitPeriodicityCustom = opts.SRSPeriodicityUE;
    else
        srsTransmitPeriodicityCustom = [];
    end
    srsTransmissionPeriodicity = calculateSRSTransmissionPeriodicity(maxUE, srsResourcePeriodicity, srsTransmitPeriodicityCustom);

    nodes = nrGNB(args{:},Position = pos,SRSPeriodicityUE=srsTransmissionPeriodicity);
    cellSite = newCellSite(nodes);

end

% Record a cell site in the h38901Scenario object
function sitesub = recordCellSite(obj,cellSite)

    sitesub = obj.theCellSiteCursor;
    obj.CellSites(obj.theCellSiteCursor) = cellSite;
    obj.NumCellSites = numel(obj.CellSites);
    obj.theCellSiteCursor = obj.theCellSiteCursor + 1;

end

% Create UEs by dropping UEs randomly across the system and attaching to
% BSs by coupling loss or path loss
function [UEs,sites,sectors,dropinfo] = createUEs(obj,varargin)

    % NOTE: The next steps are from TR 38.901 Section 7.5

    % ---------------------------------------------------------------------
    % "Step 1 a) Choose one of the scenarios"
    % Given by obj.Scenario

    % ---------------------------------------------------------------------
    % "Step 1 b) Give number of BS and UT"
    % - number of BS is obj.NumCellSites * obj.NumSectors
    % - number of UT is given in createChannelLinksByLoss

    % ---------------------------------------------------------------------
    % "Step 1 c) Give 3-D locations of BS and UT"
    % - BS locations are given by the variable 'allsitepos', the 3-D
    %   locations of each site, and the BSs (sectors) within a site
    %   will have the same location
    % - UT locations are given in createChannelLinksByLoss
    cells = cat(1,obj.CellSites.Sectors);
    allsitepos = cat(1,cat(1,cells(:,1).BS).Position);

    % ---------------------------------------------------------------------
    % Steps 1 d) - g), Steps 2, 3, 11 (partial), and 12
    % Create UEs by dropping UEs randomly across the system and attaching
    % to BSs by coupling loss or path loss and record the UE information.
    % To calculate coupling loss, Steps 4 - 10 are omitted and a subset of
    % the calculations in Step 11 are sufficient. Note that the channels
    % produced by createChannelLinksByLoss are thrown away and only the UE
    % positions, numbers of floors, 2-D indoor distances, and attachments
    % to BSs are kept and channels are re-created when the links are active
    % within wirelessNetworkSimulator. Steps 1 d) - g) and Steps 2 - 12 are
    % fully implemented in h38901Channel/channelFunction, which is executed
    % by wirelessNetworkSimulator to apply the channel to a packet for an
    % active link
    dropCfg = makeChannelLinksConfig(obj);
    dropCfg.SitePositions = allsitepos;
    
    state = makeChannelLinksState(obj);
    [~,chinfo,state] = obj.nr5g.createChannelLinksByLoss(dropCfg,state,varargin{:},SampleRate=1,FastFading=false);
    storeChannelLinksState(obj,state);
    % ---------------------------------------------------------------------
    
    obj.ChannelInfo = chinfo;

    % Create UE nodes from the positions, numbers of floors, and 2-D indoor
    % distances in the UE information; this information is stored and later
    % accessed by h38901Channel to calculate channel parameters when a
    % channel link for this node is requested by wirelessNetworkSimulator.
    % Note that 'totUEs' is the total number of UEs across all the sites
    % and sectors and 'maxUE' is the maximum number of UEs within any site
    % and sector
    ueinfo = chinfo.AttachedUEInfo;
    sites = cat(1,ueinfo.Site);
    sectors = cat(1,ueinfo.Sector);
    totUEs = numel(ueinfo);
    if (obj.ChosenUEs)
        % With ChosenUEs=true, every site and sector has the same number of
        % UEs, so 'ueinfo' is a numCellSites-by-numSectors-by-numUEs array.
        % Therefore 'maxUE' is the size of the 3rd dimension (numUEs)
        maxUE = size(ueinfo,3);
    else
        % With ChosenUEs=false, different sites and sectors likely have
        % different numbers of UEs ('ueinfo' is arranged as a column
        % vector). 'maxUE' is taken to be the same as 'totUEs', because in
        % the worst (but extremely unlikely) case all UEs may be attached
        % to the same site and sector
        maxUE = totUEs;
    end
    pos = zeros(totUEs,3);
    dropinfo = repmat(struct(NodeSubs=[],NodeSiz=[],d_2D_in=[],n_fl=[]),1,totUEs);
    for i = 1:totUEs

        BS = cells(sites(i),sectors(i)).BS;
        pos(i,:) = ueinfo(i).Position;
        if (obj.ChosenUEs)
            [~,~,ue] = ind2sub([obj.NumCellSites obj.NumSectors obj.NumUEs],i);
        else
            ue = i;
        end
        bsinfo = dropConditions(obj,BS);
        dropinfo(i).NodeSubs = [bsinfo.NodeSubs ue];
        dropinfo(i).NodeSiz = [bsinfo.NodeSiz maxUE];
        dropinfo(i).d_2D_in = round(ueinfo(i).d_2D_in,3);
        dropinfo(i).n_fl = ueinfo(i).n_fl;

    end

    % Create UEs with any name-value arguments that have been provided.
    % Remove name-value arguments that belong to the function here rather
    % than nrUE
    args = varargin;
    for n = ["TXRUVirtualization" "DropMode" "TransmitAntennaArray" "ReceiveAntennaArray" "CouplingLossInfo" "LOSProbability"]
        argidx = find(cellfun(@(x)isequal(x,n),args));
        args(argidx:argidx+1) = [];
    end
    UEs = nrUE(args{:},Position = pos);

end

% Record a set of UEs in the h38901Scenario object
function recordUEs(obj,UEs,sites,sectors)

    for i = 1:numel(UEs)
        obj.CellSites(sites(i)).Sectors(sectors(i)).UEs(end+1) = UEs(i);
    end

end

% Connect a set of UEs to a BS using the nrGNB/connectUE object function,
% including specifying traffic configuration
function connectUEs(obj,UEs,sites,sectors)

    for i = 1:numel(UEs)
        connectUE(obj.CellSites(sites(i)).Sectors(sectors(i)).BS,UEs(i),FullBufferTraffic=obj.FullBufferTraffic);
    end

end

function recordBSDrop(obj,sitesub)

    siz = [obj.NumCellSites obj.NumSectors];
    BSs = cat(2,obj.CellSites(sitesub).Sectors.BS);
    for i = 1:numel(BSs)
        subs = [sitesub i];
        obj.theBSMap(BSs(i).ID) = struct(NodeSubs=subs,NodeSiz=siz);
    end

end

function recordAddedUEDrop(obj,UEs,sites,sectors)

    ueIDs = [UEs.ID];
    totUEs = numel(UEs);
    dropinfo = repmat(struct(NodeSubs=[],NodeSiz=[],d_2D_in=[],n_fl=[]),1,totUEs);
    for i = 1:totUEs
        cellSite = obj.CellSites(sites(i)).Sectors(sectors(i));
        bsinfo = dropConditions(obj,cellSite.BS);
        site_ueIDs = [cellSite.UEs.ID];
        ue = find(site_ueIDs==ueIDs(i));
        dropinfo(i).NodeSubs = [bsinfo.NodeSubs ue];
        maxUE = numel(site_ueIDs);
        dropinfo(i).NodeSiz = [bsinfo.NodeSiz maxUE];
        dropinfo(i).d_2D_in = 0;
        dropinfo(i).n_fl = 0;
    end
    obj.theUEMap(ueIDs) = dropinfo;

end

% Initialize properties that store and access cell sites
function initializeCellSites(obj)

    if (isempty(obj.CellSites))

        % Create cell site array and its cursor
        obj.CellSites = repmat(newCellSite(),1,obj.NumCellSites);
        obj.theCellSiteCursor = 1;

    end

end

% Calculate the SRS resource periodicity based on the TDD DL-UL
% configuration
function srsResourcePeriodicity = calculateSRSResourcePeriodicity(dlULConfigTDD, subcarrierSpacing)

    % minimum SRS resource occurrence periodicity (in slots)
    minSRSResourcePeriodicity = 5;
    numSlotsDLULPattern = dlULConfigTDD.DLULPeriodicity*(subcarrierSpacing/15e3);
    % Set SRS resource periodicity as minimum value such that it is at least 5
    % slots and integer multiple of numSlotsDLULPattern
    allowedSRSPeriodicity = [1 2 4 5 8 10 16 20 32 40 64 80 160 320 640 1280 2560];
    allowedSRSPeriodicity = allowedSRSPeriodicity(allowedSRSPeriodicity>=minSRSResourcePeriodicity & ...
        ~mod(allowedSRSPeriodicity, numSlotsDLULPattern));
    srsResourcePeriodicity = allowedSRSPeriodicity(1);

end

% Calculate the minimum SRS transmission periodicity for the connected UE 
% based on the SRS resource periodicity
function srsTransmissionPeriodicity = calculateSRSTransmissionPeriodicity(numConnectedUEs, srsResourcePeriodicity, srsTransmitPeriodicityCustom)

    % Calculate the minimum SRS transmission periodicity for the connected UEs
    minSRSPeriodicityForGivenUEs = ceil(numConnectedUEs/16)*srsResourcePeriodicity;
    % Calculate the set of SRS transmission periodicity which is a multiple of
    % SRS resource periodicity and valid for the given number of connected UEs
    validSRSPeriodicity = [5 8 10 16 20 32 40 64 80 160 320 640 1280 2560];
    validSet = validSRSPeriodicity(validSRSPeriodicity>=minSRSPeriodicityForGivenUEs & ~mod(validSRSPeriodicity,srsResourcePeriodicity));
    
    if ~isempty(srsTransmitPeriodicityCustom)
        if ismember(srsTransmitPeriodicityCustom, validSet)
            srsTransmissionPeriodicity = srsTransmitPeriodicityCustom;
        else
            % SRS periodicity must be one of the elements in the validSet
            if ~isempty(validSet)
                formattedValidSRSSetStr = [sprintf('{') (sprintf(repmat('%d, ', 1, length(validSet)-1)', validSet(1:end-1) )) sprintf('%d}', validSet(end))];
                messageString = ". Set the SRS periodicity to one of these values: " + formattedValidSRSSetStr + ".";
            else
                messageString = ".";
            end
            error('nr5g:h38901Scenario:InvalidSRSPeriodicityUE','Given SRS transmission periodicity (%d) is either invalid or insufficient for the number of connected UEs (%d)%s', srsTransmitPeriodicityCustom, numConnectedUEs, messageString);
        end
    else
        if ~isempty(validSet)
            srsTransmissionPeriodicity = validSet(1);
        else
            % Maximum number of the connected UEs with the maximum SRS periodicity
            maxUEWithSRSPeriodicity = 16*(validSRSPeriodicity(end)/srsResourcePeriodicity);
            error('nr5g:h38901Scenario:InvalidNumUEs', 'The number of connected UEs must not exceed (%d). Reduce the UEs connected to this gNB.', maxUEWithSRSPeriodicity);
        end
    end

end

% Validate DLULConfigTDD
function validateDLULTDDConfig(dlulConfigTDD, subcarrierSpacing)
 
    validateattributes(dlulConfigTDD, {'struct'}, {'nonempty'}, 'DLULConfigTDD', 'DLULConfigTDD');
    
    if ~isfield(dlulConfigTDD, 'DLULPeriodicity')
        coder.internal.error('nr5g:nrGNB:MissingDLULConfigField', 'DLULPeriodicity');
    end
    
    validSCS = [15e3 30e3 60e3 120e3];
    numerology = find(validSCS==subcarrierSpacing, 1, 'first');
    % Validate the DL-UL pattern duration
    validDLULPeriodicity{1} = { 1 2 5 10 }; % Applicable for scs = 15e3 Hz
    validDLULPeriodicity{2} = { 0.5 1 2 2.5 5 10 }; % Applicable for scs = 30e3 Hz
    validDLULPeriodicity{3} = { 0.5 1 1.25 2 2.5 5 10 }; % Applicable for scs = 60e3 Hz
    validDLULPeriodicity{4} = { 0.5 0.625 1 1.25 2 2.5 5 10 }; % Applicable for scs = 120e3 Hz
    validSet = cell2mat(validDLULPeriodicity{numerology});
    if ~ismember(dlulConfigTDD.DLULPeriodicity, validSet) % DLULPeriodicity is not valid for the specified numerology
        formattedValidSetStr = [sprintf('{') (sprintf(repmat('%.3f, ', 1, length(validSet)-1)', validSet(1:end-1) )) sprintf('%.3f}', validSet(end))];
        coder.internal.error('nr5g:nrGNB:InvalidDLULPeriodicity', ""+dlulConfigTDD.DLULPeriodicity, formattedValidSetStr);
    end

end

%% ========================================================================
%  local functions independent of wirelessNetworkSimulator
%  ========================================================================

% BS position for a site
function pos = bsPositions(obj,siteIndex,h_BS)

    numCellsPerSite = numel(h_BS);
    sitepos = obj.theSitePositions(siteIndex,:);
    pos = repmat(sitepos,numCellsPerSite,1);
    pos(:,3) = h_BS;

end

% Create a new cell
function c = newCell(varargin)

    c = struct();
    if (nargin==0)
        c.BS = [];
    else
        bs = varargin{1};
        c.BS = bs;
    end
    c.UEs = nrUE.empty;

end

% Create a new cell site
function cs = newCellSite(varargin)

    cs = struct();
    if (nargin==0)
        c = newCell();
        cs.Sectors = c([]);
    else
        cs.Sectors = arrayfun(@newCell,varargin{1});
    end

end

% Set object properties from name-value arguments
function setProperties(obj,varargin)

    s = parseInputs(struct(),varargin{:});
    ns = string(fieldnames(s)).';
    for n = ns
        if (isprop(obj,n))
            obj.(n) = s.(n);
        end
    end

end

% Set structure fields from name-value arguments
function s = parseInputs(s,varargin)

    for i = 1:2:numel(varargin)
        n = varargin{i};
        v = varargin{i+1};
        s.(n) = v;
    end

end

% Set the channel bandwidth according to TR 38.901 Tables 7.8-1 and 7.8-2
function b = cbw(obj)
    
    if (isFR2(obj))
        b = 100e6;
    else
        b = 20e6;
    end

end

% Set the subcarrier spacing to valid values for the channel bandwidths
% specified in TR 38.901 Tables 7.8-1 and 7.8-2
function s = scs(obj)

    if (isFR2(obj))
        s = 60e3;
    else
        s = 15e3;
    end

end

% Determine if a configuration has an FR2 carrier frequency, according to 
% TS 38.104 Table 5.1-1
function fr2 = isFR2(obj)

    fr2 = (obj.CarrierFrequency > 7.125e9);

end

% Set the transmit power according to the scenario
function p = txPower(obj)
    
    % TR 38.901 Tables 7.8-1 and 7.8-2
    if (isFR2(obj))
        pUMa = 35;
        pUMi = 35;
    else        
        pUMa = 49;
        pUMi = 44;
    end
    % TR 38.802 Table A.2.1-1
    pRMa = 49;

    p = obj.nr5g.scenarioSwitch(obj.Scenario,pUMi,pUMa,pRMa);

end

function v = getScenarioExtents(obj,sites)

    % Get polygons that are the boundaries for each site
    ISD = obj.InterSiteDistance;
    [sitex,sitey] = obj.nr5g.sitePolygon(ISD);
    % Get bounding box of the union of the site polygons
    sysx = sites(:,1) + sitex;
    sysy = sites(:,2) + sitey;
    minpos = [min(sysx, [], 'all'), min(sysy, [], 'all')];
    maxpos = [max(sysx, [], 'all'), max(sysy, [], 'all')];
    v = [minpos maxpos-minpos];

end

function dropCfg = makeChannelLinksConfig(obj)

    dropCfg = struct();
    dropCfg.NumCellSites = obj.NumCellSites;
    dropCfg.NumSectors = obj.NumSectors;
    dropCfg.NumUEs = obj.NumUEs;
    dropCfg.ChosenUEs = obj.ChosenUEs;
    dropCfg.Wrapping = obj.Wrapping;
    dropCfg.SpatialConsistency = spatialConsistencyString(obj.SpatialConsistency);
    dropCfg.Scenario = obj.Scenario;
    dropCfg.IndoorRatio = obj.IndoorRatio;
    dropCfg.CarrierFrequency = obj.CarrierFrequency;
    dropCfg.InterSiteDistance = obj.InterSiteDistance;
    dropCfg.Seed = obj.Seed;

end

function state = makeChannelLinksState(obj)

    state = struct();
    state.theUECount = obj.theUECount;
    state.theRandStream = obj.theRandStream;
    state.thePathLossConfig = obj.thePathLossConfig;
    state.theAutoCorrMatrices = obj.theAutoCorrMatrices;
    state.theFirstCoord = obj.theFirstCoord;
    state.SCRVs = obj.SCRVs;

end

function storeChannelLinksState(obj,state)

    obj.theUECount = state.theUECount;
    obj.theAutoCorrMatrices = state.theAutoCorrMatrices;
    obj.theFirstCoord = state.theFirstCoord;
    obj.SCRVs = state.SCRVs;

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

function validateSpatialConsistency(val)

    if (~isnumeric(val) && ~islogical(val))
        mustBeTextScalar(val);
        matlab.system.mustBeMember(val, ...
            ["None" "Static" "ProcedureA" "ProcedureB"]);
    end

end

function args = validateChannelLinksArgs(varargin)

    args = varargin;
    idx = find(cellfun(@(x)isequal(x,'DropMode'),args),1);
    if (~isempty(idx))
        args{idx+1} = validatestring(args{idx+1},{'PathLoss' 'CouplingLoss'});
    end

end
