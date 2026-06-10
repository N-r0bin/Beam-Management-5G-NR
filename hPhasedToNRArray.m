function antennaArrayOut = hPhasedToNRArray(antennaArrayIn,lambda)
% hPhasedToNRArray Converts a phased antenna array to a 5G antenna array
%
% Convert a phased.NRRectangularPanelArray to a 5G antenna array
% structure to feed into nrCDLChannel for speed purposes. If the input
% is not a phased.NRRectangularPanelArray object with the ElementSet
% property set to phased.NRAntennaElement, the output is the same as
% the input.

%   Copyright 2024 The MathWorks, Inc.

if isa(antennaArrayIn,"phased.NRRectangularPanelArray") && ...
        isa(antennaArrayIn.ElementSet{1},"phased.NRAntennaElement") % This assumes that all values of ElementSet are of the same type
    antennaArrayOut = struct();
    antennaArrayOut.Size = [antennaArrayIn.Size(1:2) 2 antennaArrayIn.Size(3:4)];
    antennaArrayOut.ElementSpacing = antennaArrayIn.Spacing/lambda;
    antennaArrayOut.PolarizationAngles = cellfun(@(x)x.PolarizationAngle,antennaArrayIn.ElementSet);
    firstElementSet = antennaArrayIn.ElementSet{1};
    antennaArrayOut.PolarizationModel = "Model-" + firstElementSet.PolarizationModel; % This assumes that all antenna elements have the same polarization model
    isIsotropic = firstElementSet.MaximumGain<=eps && ...
        firstElementSet.MaximumAttenuation<=eps && ...
        all(firstElementSet.Beamwidth==[180 180]) && ...
        all(firstElementSet.SidelobeLevel<=eps);
    if isIsotropic
        antennaArrayOut.Element = "isotropic";
    else
        antennaArrayOut.Element = "38.901";
    end
else
    % Input antenna array is not the requested one. Return it
    % unchanged.
    antennaArrayOut = antennaArrayIn;
end
end