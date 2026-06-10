% hSSBurstTimingOffset Get the timing offset for SSBurst time correction

%   Copyright 2024 The MathWorks, Inc.

function offset = hSSBurstTimingOffset(rxWaveform,carrier,ofdmInfo,burstOccupiedSymbols)

arguments
    rxWaveform           (:,:) double          % Received SSB waveform
    carrier              (1,1) nrCarrierConfig % Carrier configuration parameters
    ofdmInfo             (1,1) struct          % OFDM information structure
    burstOccupiedSymbols (:,4) {mustBeNumeric} % Matrix of SSB occupied OFDM symbols, in which each row corresponds to a block
end

refGrid = generateReferenceGrid(carrier);
offset = nrTimingEstimate(rxWaveform,20,carrier.SubcarrierSpacing,0,refGrid,SampleRate=ofdmInfo.SampleRate);

% Get the starting sample of each symbol for 5 subframes, as this is
% the maximum SSBurst length
cs = cumsum([0 repmat(ofdmInfo.SymbolLengths,1,5)]);

% Use the known occupied symbols to get the expected timing offset and
% compare with the offset from nrTimingEstimate
blocksFirstSample = (cs(burstOccupiedSymbols(:,1)) - ofdmInfo.SymbolLengths(1));
ssbIndex = find(offset >= blocksFirstSample,1,'last');
offset = offset - blocksFirstSample(ssbIndex);
if isempty(offset)
    % ssbIndex is undefined. Set the offset to inf to signal failed
    % timing estimation.
    offset = inf;
end
end

function refGrid = generateReferenceGrid(carrier)
% Generate a reference grid for timing correction
ncellid = carrier.NCellID;
pssRef = nrPSS(ncellid);
pssInd = nrPSSIndices;
sssRef = nrSSS(ncellid);
sssInd = nrSSSIndices;
ssbGrid = zeros([240 4]);
ssbGrid(pssInd) = pssRef;
ssbGrid(sssInd) = sssRef;
refGrid = [zeros(240,1) ssbGrid]; % Adding an extra OFDM symbol for correct CP length
end