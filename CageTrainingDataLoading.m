% Script for combinging and transform json data from cage trainers
% Feb,09,2026 by Xuefei Yu

clc; clear;

% -----------------------------
% configure
% -----------------------------

%Raw Data loading path
%from server
%{
monkey = 'Monkey Porthos';
main_path = '/Volumes/server/';
data_date = '2025-11-05'; % in yyyy-mm-dd
task_type = 'cage_training/timedelay';
%}
%from dropbox to local
monkey = 'Monkey Porthos';
main_path = '/Users/xuefeiyu/Documents/XuefeiFile/WorkRelated/Data/';
data_date = '2026-06-05'; % in yyyy-mm-dd
task_type = 'cage_training/timedelay';
local_label = 'raw';

folder_path = fullfile(main_path, monkey, task_type,local_label,data_date);


%Data output path
main_output_path = '/Users/xuefeiyu/Documents/XuefeiFile/WorkRelated/Data';
monkey_specific_path = fullfile(monkey,task_type);
output_path = fullfile(main_output_path,monkey_specific_path);
% Create output directory if it doesn't exist
if ~exist(output_path, 'dir')
    mkdir(output_path);
end

output_csv = sprintf('all_trials_%s.csv', data_date);
output_file = fullfile(output_path,output_csv);


% load all json files from the folder
files = dir(fullfile(folder_path, '*.json'));

% initiating the table
allData = table();


% -----------------------------
% load JSON files one by one
% -----------------------------
for i = 1:length(files)
    filename = files(i).name;
    filepath = fullfile(folder_path, filename);

    % read JSON file
    jsonText = fileread(filepath);
    decoded  = jsondecode(jsonText);

    % A trial file is a JSON *array*: usually one trial, but if the tablet
    % lost wifi and reconnected, several trials can be batched into one file.
    % jsondecode returns that array in one of two shapes:
    %   - a struct array,         when every trial has the same set of fields
    %   - a cell array of structs, when the trials have different fields
    % (and a single scalar struct when the file holds just one trial).
    % Normalise all three into one cell array with one trial struct per cell,
    % so the rest of the loop can treat every file as "a list of trials".
    if iscell(decoded)
        trials = decoded;               % heterogeneous trials: already a cell
    elseif isstruct(decoded)
        trials = num2cell(decoded);     % scalar struct or struct array -> one cell per trial
    else
        warning('Skipping %s: unexpected JSON shape (not an object/array).', filename);
        continue;
    end

    if numel(trials) > 1
        fprintf('%s: %d trials batched in one file\n', filename, numel(trials));
    end

    % turn each trial into a one-row table and append it
    for j = 1:numel(trials)
        trial = trials{j};

        % replace any empty value ([] / null) with NaN so struct2table is happy
        trial = structfun(@(x) fillEmptyWithNaN(x), trial, 'UniformOutput', false);

        % flatten this single trial into a one-row table ('AsArray' keeps any
        % vector-valued field as one cell instead of spreading it over rows)
        T = struct2table(trial, 'AsArray', true);
        T.trial_file = string(filename);

        % response is text ("left"/"right"); some tasks (e.g. touch) don't have it
        if ismember('response', T.Properties.VariableNames)
            T.response = string(T.response);
        end

        % append, aligning columns by name so trials/files that carry
        % different field sets still stack instead of erroring
        allData = appendTrialRow(allData, T);
    end
end

% -----------------------------
% save into new file
% -----------------------------
if isempty(allData)
    error('No data found, check whether the data folder exist!')
else
    writetable(allData, output_file);
    disp(['All trials has been combined into ', output_file]);
    disp(head(allData));
end





function y = fillEmptyWithNaN(x)
    if isempty(x)
        y = NaN;
    else
        y = x;
    end

end

function combined = appendTrialRow(existing, T)
% Vertically stack the one-row table T onto existing, matching columns by
% name. Any column missing from either side is added and filled with
% <missing> (which becomes NaN in a numeric column, <missing> in a text one),
% so trials or files that carry different fields still stack instead of
% throwing a "variable names must match" error.
    if isempty(existing)
        combined = T;
        return;
    end

    % columns T has but existing doesn't -> add them to existing (filled)
    newCols = setdiff(T.Properties.VariableNames, existing.Properties.VariableNames, 'stable');
    for c = 1:numel(newCols)
        existing.(newCols{c}) = repmat(missing, height(existing), 1);
    end

    % columns existing has but T doesn't -> add them to T (filled)
    absentCols = setdiff(existing.Properties.VariableNames, T.Properties.VariableNames, 'stable');
    for c = 1:numel(absentCols)
        T.(absentCols{c}) = missing;
    end

    % put T's columns in the same order as existing, then stack
    T = T(:, existing.Properties.VariableNames);
    combined = [existing; T];
end