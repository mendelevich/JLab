function ct_to_shared(inputCsv, task, monkey, outputCsv, mapPath)
% CT_TO_SHARED  Convert a Cage-Training trial CSV to the shared CT/BR schema.
%
%   ct_to_shared(inputCsv, task, monkey, outputCsv)
%   ct_to_shared(inputCsv, task, monkey, outputCsv, mapPath)
%
% Reads the CSV produced by CageTrainingDataLoading.m (all_trials_<date>.csv,
% one row per trial) and writes a CSV whose columns are the shared variable
% names, filling each from the cage side of the map.
%
% The MAP is schema_map.json (the single source of truth, shared with the Python
% converters in JLab_Python). This file interprets each entry's "ct" spec and
% holds the cage-specific compute transforms (see computeValue below). To change
% WHICH cage column feeds a shared variable, edit schema_map.json. To change HOW a
% derived value is computed, edit computeValue.
%
% `task` is one of: touch | touchdot | touchdotRL | motion | timedelay
% (the cage CSV does not carry the task, so it must be passed in).
%
% Example:
%   ct_to_shared('all_trials_2026-08-12.csv', 'timedelay', 'Porthos', 'shared.csv')
%
% NOTE: not yet validated in MATLAB against real cage data. Transforms with a
% "CHECK" comment are unverified encodings.

    if nargin < 5 || isempty(mapPath)
        mapPath = fullfile(fileparts(mfilename('fullpath')), 'schema_map.json');
    end

    % --- load the cage trials and the map ---
    T = readtable(inputCsv);
    entries = jsondecode(fileread(mapPath));
    if isstruct(entries)              % homogeneous -> struct array; normalise to cell
        entries = num2cell(entries);
    end

    nRows = height(T);
    ctx = struct('task', task, 'monkey', monkey);
    out = table();

    for i = 1:numel(entries)
        e = entries{i};

        % skip optional (derived/measured) rows
        if isfield(e, 'skip') && ~isempty(e.skip) && e.skip
            continue;
        end
        shared = e.shared;

        % applies_to gating: if listed and this task isn't in it -> NaN column
        applies = true;
        if isfield(e, 'applies_to') && ~isempty(e.applies_to)
            at = e.applies_to;
            if ischar(at); at = {at}; end
            applies = any(strcmp(task, at));
        end

        if ~applies
            col = nan(nRows, 1);
        elseif isfield(e, 'ct')
            col = evalSpec(e.ct, T, ctx, nRows, shared);
        else
            col = nan(nRows, 1);
        end

        out.(shared) = col;
    end

    writetable(out, outputCsv);
    fprintf('Wrote %d rows x %d cols -> %s\n', height(out), width(out), outputCsv);
end


% ----------------------------------------------------------------------------------
% Interpret one "ct" spec (a struct with exactly one field naming the rule).
% ----------------------------------------------------------------------------------
function col = evalSpec(spec, T, ctx, nRows, shared)
    if isempty(spec)
        col = nan(nRows, 1); return;
    end
    if isfield(spec, 'direct')
        col = getCol(T, spec.direct, nRows, shared); return;
    end
    if isfield(spec, 'by_task')
        if isfield(spec.by_task, ctx.task)
            col = getCol(T, spec.by_task.(ctx.task), nRows, shared);
        else
            col = nan(nRows, 1);          % this task has no column for the field
        end
        return;
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
        warning('ct_to_shared:todo', '[%s] TODO: %s', shared, spec.todo);
        col = nan(nRows, 1); return;
    end
    if isfield(spec, 'compute')
        col = computeValue(spec.compute, T, ctx, nRows, shared); return;
    end
    warning('ct_to_shared:spec', '[%s] unrecognised spec; filling NaN', shared);
    col = nan(nRows, 1);
end


% ----------------------------------------------------------------------------------
% Cage compute transforms (the "compute: NAME" specs). Mirror ct_to_shared.py.
% ----------------------------------------------------------------------------------
function col = computeValue(name, T, ctx, nRows, shared)
    switch name
        case 'row_index'                     % 0-based row counter
            col = (0:nRows-1)';

        case 'session'                       % CHECK: bump when trialnumber resets
            tn = getNumericCol(T, 'trialnumber', nRows, shared);
            col = cumsum([false; diff(tn) < 0]) + 1;

        case 'direction_sign'                % +1 right, -1 left
            col = directionSign(T, nRows, shared);

        case 'stimulus_coherence'            % CHECK: signed by direction?
            col = getNumericCol(T, 'coherence', nRows, shared) .* directionSign(T, nRows, shared);

        case 'choice_rightward'              % response right -> +1, left -> -1
            col = responseSign(T, nRows, shared);

        case 'choice_target'                 % accuracy 1 -> target 1, 0 -> target 2
            acc = getNumericCol(T, 'accuracy', nRows, shared);
            col = nan(nRows, 1);
            col(acc == 1) = 1;
            col(acc == 0) = 2;

        case 'is_single_choice'              % only the correct target shown
            col = getCol(T, 'onlyShowCorrect', nRows, shared);

        case 'fixation_x'
            col = touchOrConst(T, ctx, nRows, shared, 'xposAbs', 0);
        case 'fixation_y'
            col = touchOrConst(T, ctx, nRows, shared, 'yposAbs', 0);

        case 'target_1_side'                 % correct side tracks direction
            ds = directionSign(T, nRows, shared);
            col = strings(nRows, 1);
            col(ds == 1)  = "right";
            col(ds == -1) = "left";

        case 'target_1_angle'                % right +90, left -90
            col = directionSign(T, nRows, shared) * 90;
        case 'target_2_angle'                % opposite of target 1
            col = directionSign(T, nRows, shared) * -90;

        case 'target_1_x'                    % touchdotRL: xposAbs; motion/timedelay: 0.8/0.2
            if strcmp(ctx.task, 'touchdotRL')
                col = getNumericCol(T, 'xposAbs', nRows, shared);
            elseif any(strcmp(ctx.task, {'motion', 'timedelay'}))
                ds = directionSign(T, nRows, shared);
                col = nan(nRows, 1); col(ds == 1) = 0.8; col(ds == -1) = 0.2;
            else
                col = nan(nRows, 1);
            end
        case 'target_2_x'                    % opposite side of target 1
            ds = directionSign(T, nRows, shared);
            col = nan(nRows, 1); col(ds == 1) = 0.2; col(ds == -1) = 0.8;
        case 'target_1_y'                    % touchdotRL: yposAbs; motion/timedelay: 0
            col = touchOrConst(T, ctx, nRows, shared, 'yposAbs', 0, {'motion', 'timedelay'});
        case 'target_2_y'
            col = zeros(nRows, 1);

        otherwise
            warning('ct_to_shared:compute', '[%s] compute ''%s'' not implemented; filling NaN', shared, name);
            col = nan(nRows, 1);
    end
end


% ----------------------------------------------------------------------------------
% Small helpers.
% ----------------------------------------------------------------------------------
function col = getCol(T, name, nRows, shared)
% Return cage column `name`, or all-NaN (with a warning) if it's missing.
    if ismember(name, T.Properties.VariableNames)
        col = T.(name);
    else
        warning('ct_to_shared:missing', '[%s] source column ''%s'' not found; filling NaN', shared, name);
        col = nan(nRows, 1);
    end
end

function v = getNumericCol(T, name, nRows, shared)
    c = getCol(T, name, nRows, shared);
    if isnumeric(c)
        v = c;
    else
        v = str2double(string(c));
    end
end

function s = toStringCol(c)
% Coerce any column type to a string column (logical/numeric/cell/categorical/string).
    s = string(c);
end

function ds = directionSign(T, nRows, shared)
% `direction` -> +1 (right/true) or -1 (left/false). Robust to bool / 0-1 / "true"/"false".
% CHECK: confirm the encoding readtable produces for `direction` on real data.
    s = toStringCol(getCol(T, 'direction', nRows, shared));
    ds = nan(nRows, 1);
    ds(strcmpi(s, "true")  | s == "1") = 1;
    ds(strcmpi(s, "false") | s == "0") = -1;
end

function col = responseSign(T, nRows, shared)
% response "right" -> +1, "left" -> -1.
% CHECK: some cage tasks may use up/down responses; extend if so.
    s = toStringCol(getCol(T, 'response', nRows, shared));
    col = nan(nRows, 1);
    col(strcmpi(s, "right")) = 1;
    col(strcmpi(s, "left"))  = -1;
end

function col = touchOrConst(T, ctx, nRows, shared, absCol, constVal, tasks)
% touchdotRL -> the absolute touch column; the given tasks (default: all) -> constVal.
    if strcmp(ctx.task, 'touchdotRL')
        col = getNumericCol(T, absCol, nRows, shared);
        return;
    end
    if nargin < 7 || isempty(tasks) || any(strcmp(ctx.task, tasks))
        col = repmat(constVal, nRows, 1);
    else
        col = nan(nRows, 1);
    end
end
