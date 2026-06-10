% hSSBurstRSRP Compute RSRP for the SSBurst

%   Copyright 2024 The MathWorks, Inc.

function rsrp = hSSBurstRSRP(rxSSBGrid,ncellid,transmittedBlocks,ssbIndex,RSRPMode)

    arguments
        % Mandatory inputs
        rxSSBGrid            (240,4) {mustBeNumeric} % Received SSB grid
        ncellid              (1,1)   {mustBeNumeric} % Cell ID
        transmittedBlocks    (1,:)   {mustBeNumeric} % SSB transmitted blocks, specified as a row vector of 1s and 0s
        ssbIndex             (1,1)   {mustBeNumeric} % Index of the current block

        % Optional inputs
        % Method to compute the RSRP: "SSSonly" uses SSS alone, "SSSwDMRS"
        % uses SSS and PBCH DM-RS.
        RSRPMode {mustBeMember(RSRPMode,["SSSwDMRS","SSSonly"])} = "SSSwDMRS"
    end

    if RSRPMode=="SSSwDMRS"
        % Compute ibar_SSB for this block index
        ibar_SSB_all = calculateIbarSSB(transmittedBlocks);
        ibar_SSB = ibar_SSB_all(ssbIndex);
    else % "SSSonly"
        % ibar_SSB is not used when PBCH DM-RS is not used. Set it to empty
        ibar_SSB = [];
    end

    % Equalize the SSB grid for any potential wrong offset, using
    % linear phase compensation
    eqSSBGrid = equalizePhaseGrid(rxSSBGrid,ncellid,ibar_SSB);

    % Compute the RSRP
    meas = nrSSBMeasurements(eqSSBGrid,ncellid,ibar_SSB);

    % Because of the beam combining, the received SSB grid is
    % single-plane always. For this reason, the RSRPPerAntenna field of
    % the nrSSBMeasurement output is always a scalar.
    rsrp = meas.RSRPPerAntenna; % dBm
end

function ibar_SSB = calculateIbarSSB(transmittedBlocks)
    % Calculate the list of values for ibar_SSB, assuming a 0 ms half-frame
    % offset of SS Burst
    tmp = find(transmittedBlocks) - 1;
    if length(transmittedBlocks)==4
        tmp2 = mod(tmp,4);
        n_hf = 0;
        ibar_SSB = tmp2 + 4*n_hf;
    else
        ibar_SSB = mod(tmp,8);
    end
end

function eqSSBGrid = equalizePhaseGrid(rxSSBGrid,ncellid,varargin)
    % Use linear phase compensation to equalize the SSB grid for any
    % potential wrong offset

    if nargin == 3 && ~isempty(varargin{1})
        pbchInd = nrPBCHDMRSIndices(ncellid);
        pbchRef = nrPBCHDMRS(ncellid,varargin{1});
    else
        pbchInd = [];
        pbchRef = [];
    end
    pssRef = nrPSS(ncellid);
    pssInd = nrPSSIndices;
    sssRef = nrSSS(ncellid);
    sssInd = nrSSSIndices;
    rsIndices = [pssInd; sssInd; pbchInd];
    rsSymbols = [pssRef; sssRef; pbchRef];
    K = size(rxSSBGrid,1);
    L = size(rxSSBGrid,2);
    [ksubs,lsubs] = ind2sub([K L],double(rsIndices));
    eqSSBGrid = linearPhaseEqualize(rxSSBGrid,rsIndices,rsSymbols,K,ksubs,lsubs);
end

function out = linearPhaseEqualize(in,rsIndices,rsSymbols,K,ksubs,lsubs)
    % Linear phase equalization for 5G NR reference signals

    arguments
        in        (:,:) {mustBeNumeric} % Input grid for a single receive antenna
        rsIndices (:,1) {mustBeNumeric} % Reference signal indices
        rsSymbols (:,1) {mustBeNumeric} % Reference signal symbols
        K         (1,1) {mustBeNumeric} % Number of subcarriers
        ksubs     (:,:) {mustBeNumeric} % Reference signal occupied subcarriers
        lsubs     (:,:) {mustBeNumeric} % Reference signal occupied symbols
    end

    nports = size(ksubs,2);
    rsIndices = reshape(rsIndices,[],nports);
    rsSymbols = reshape(rsSymbols,[],nports);
    refSyms = unique(lsubs);
    nsyms = length(refSyms);
    thetapoly = zeros(nsyms*nports,2);
    rms = zeros(nsyms*nports,1);
    for p = 1:nports
        lsubsp = lsubs(:,p);
        for li = 1:nsyms
            l = refSyms(li);
            theta = myUnwrap(angle(in(rsIndices(lsubsp==l,p)).*conj(rsSymbols(lsubsp==l,p))));
            [thetapoly(li + (p-1)*nsyms,:),s] = polyfit(ksubs(lsubsp==l,p),theta,1);
            rms(li + (p-1)*nsyms) = s.normr/sqrt(numel(theta)-1);
        end
    end
    threshold = 1.2;
    if (sum(rms<threshold)>0)
        thetapoly = mean(thetapoly(rms<threshold,:),1);
        theta = polyval(thetapoly,(1:K).');
    else
        theta = 0;
    end
    out = in .* exp(-1i*theta);

end

function y = myUnwrap(x)
    % Stripped-down version of unwrap that only performs the job that is
    % needed in this use case, without the same generality and input checks
    % that the official unwrap function provides.

    arguments
        x (:,1) % Force input (and therefore output) to be column vector
    end

    d = diff(x);
    jumps = abs(d)>=pi;
    jumpsd = double(jumps);

    jumpsd(jumps) = -2*pi*sign(d(jumps));
    y = cumsum([0; jumpsd]) + x;
end