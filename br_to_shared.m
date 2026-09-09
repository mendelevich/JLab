function br_to_shared(inputCsv, monkey, outputCsv, mapPath)
% BR_TO_SHARED  Convert a BlackRock trials CSV to the shared CT/BR schema.
%
%   br_to_shared(inputCsv, monkey, outputCsv)
%   br_to_shared(inputCsv, monkey, outputCsv, mapPath)
%
% Reads the Blackrock_<date>_trials_matlab.csv produced by BlackrockLoader (one
% row per trial) and writes a CSV whose columns are the shared variable names,
% filling each from the BlackRock side of the map.
%
% Uses the SAME map as the cage converter (schema_map.json), applying the "br"
% side of each entry. This is TASK-AGNOSTIC: unlike ct_to_shared.m there is no
% `task`, so `applies_to` is NOT used to gate columns -- a shared variable whose
% BR column isn't present in a given session simply comes through as NaN. That
% keeps single- vs multi-target sessions robust without translating BlackRock's
% task names into the cage task vocabulary.
%
% Most BR specs are `direct:` (BlackrockLoader already exports these exact column
% names), so there are no compute transforms yet -- add cases to computeValue
% below only if a shared variable ever needs a real transform on the BR side.
%
% Example:
%   br_to_shared('Blackrock_2026-07-24_trials_matlab.csv', 'Athos', 'shared_br.csv')
%
% NOTE: not yet validated in MATLAB against a real BlackRock trials CSV.

    if nargin < 4 || isempty(mapPath)
        mapPath = fullfile(fileparts(mfilename('fullpath')), 'schema_map.json');
    end

    T = readtable(inputCsv);
    entries = jsondecode(fileread(mapPath));
    if isstruct(entries)
        entries = num2cell(entries);
    end

    nRows = height(T);
    ctx = struct('monkey', monkey);       % no task on the BR side
    out = table();

    for i = 1:numel(entries)
        e = entries{i};
        if isfield(e, 'skip') && ~isempty(e.skip) && e.skip
            continue;                     % optional (derived/measured) rows
        end
        shared = e.shared;

        if isfield(e, 'br')
            col = evalSpec(e.br, T, ctx, nRows, shared);
        else
            col = nan(nRows, 1);
        end
        out.(shared) = col;
    end

    writetable(out, outputCsv);
    fprintf('Wrote %d rows x %d cols -> %s\n', height(out), width(out), outputCsv);
end


% ----------------------------------------------------------------------------------
% Interpret one "br" spec (a struct with exactly one field naming the rule).
% ----------------------------------------------------------------------------------
function col = evalSpec(spec, T, ctx, nRows, shared)
    if isempty(spec)
        col = nan(nRows, 1); return;
    end
    if isfield(spec, 'direct')
        col = getCol(T, spec.direct, nRows, shared); return;
    end
    if isfield(spec, 'const')
        v = spec.const;
        if ischar(v) || isstring(v)
            col = repmat(string(v), nRows, 1);
        else
            col = repmat(v, nRows, 1);
        end
        return;
    end
    if isfield(spec, 'const_ctx')
        col = repmat(string(ctx.(spec.const_ctx)), nRows, 1); return;
    end
    if isfield(spec, 'na')
        col = nan(nRows, 1); return;
    end
    if isfield(spec, 'todo')
        warning('br_to_shared:todo', '[%s] TODO: %s', shared, spec.todo);
        col = nan(nRows, 1); return;
    end
    if isfield(spec, 'by_task')
        % no task on the BR side -> can't pick a column; leave NaN.
        col = nan(nRows, 1); return;
    end
    if isfield(spec, 'compute')
        col = computeValue(spec.compute, T, ctx, nRows, shared); return;
    end
    warning('br_to_shared:spec', '[%s] unrecognised spec; filling NaN', shared);
    col = nan(nRows, 1);
end


% ----------------------------------------------------------------------------------
% BlackRock compute transforms. Empty for now -- BlackrockLoader's CSV already
% carries the columns the map points at, so every br spec is direct/na/const. Add a
% `case 'name'` here if a shared variable ever needs a real transform on the BR side,
% then reference it from the map as  br: { compute: name }.
% ----------------------------------------------------------------------------------
function col = computeValue(name, T, ctx, nRows, shared) %#ok<INUSD>
    warning('br_to_shared:compute', '[%s] compute ''%s'' not implemented; filling NaN', shared, name);
    col = nan(nRows, 1);
end


function col = getCol(T, name, nRows, shared)
% Return BR column `name`, or all-NaN (with a warning) if it's missing.
    if ismember(name, T.Properties.VariableNames)
        col = T.(name);
    else
        warning('br_to_shared:missing', '[%s] source column ''%s'' not found; filling NaN', shared, name);
        col = nan(nRows, 1);
    end
end
