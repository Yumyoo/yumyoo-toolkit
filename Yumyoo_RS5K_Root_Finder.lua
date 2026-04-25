-- @description Yumyoo RS5K Root Finder
-- @author Yumyoo
-- @version 1.0
-- @about A background script that monitors ReaSamplOmatic5000 instances. It automatically parses loaded sample filenames for musical keys (e.g., '808 [C#].wav') and calculates the exact mathematical offset to tune the sample UP to A4.

local last_filenames = {}

function loop()
    local num_tracks = reaper.CountTracks(0)
    
    for t = 0, num_tracks - 1 do
        local track = reaper.GetTrack(0, t)
        local track_guid = reaper.GetTrackGUID(track)
        
        for i = 0, reaper.TrackFX_GetCount(track) - 1 do
            local fx_guid = reaper.TrackFX_GetFXGUID(track, i)
            local plugin_id = track_guid .. fx_guid
            
            local is_rs5k = false
            local pitch_idx = -1
            local num_params = reaper.TrackFX_GetNumParams(track, i)
            
            for p = 0, num_params - 1 do
                local _, p_name = reaper.TrackFX_GetParamName(track, i, p, "")
                if p_name:lower() == "pitch adjust" then
                    is_rs5k = true
                    pitch_idx = p
                    break
                end
            end
            
            if is_rs5k then
                local ret, full_path = reaper.TrackFX_GetNamedConfigParm(track, i, "FILE")
                if not ret or full_path == "" then
                    ret, full_path = reaper.TrackFX_GetNamedConfigParm(track, i, "FILE0")
                end
                
                if ret and full_path and full_path ~= "" and full_path ~= last_filenames[plugin_id] then
                    last_filenames[plugin_id] = full_path
                    
                    local filename = full_path:match("^.+[/\\](.+)$") or full_path
                    local lower_filename = filename:lower()
                    
                    local key = string.match(lower_filename, "[%s_%-%(%[]([a-g][%#b]?)[%s_%-%.%)%]]")
                    
                    if key then
                        local offsets_to_A = {
                            ["a"]  = 0,
                            ["a#"] = 11, ["bb"] = 11,
                            ["b"]  = 10,
                            ["c"]  = 9,
                            ["c#"] = 8,  ["db"] = 8,
                            ["d"]  = 7,
                            ["d#"] = 6,  ["eb"] = 6,
                            ["e"]  = 5,
                            ["f"]  = 4,
                            ["f#"] = 3,  ["gb"] = 3,
                            ["g"]  = 2,
                            ["g#"] = 1,  ["ab"] = 1
                        }
                        
                        if offsets_to_A[key] then
                            local offset = offsets_to_A[key]
                            local param_val = (offset + 80) / 160
                            reaper.TrackFX_SetParamNormalized(track, i, pitch_idx, param_val)
                        end
                    end
                end
            end
        end
    end
    
    reaper.defer(loop)
end

loop()
