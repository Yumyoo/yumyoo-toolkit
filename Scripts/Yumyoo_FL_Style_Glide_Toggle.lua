-- @description Yumyoo FL-Style MIDI Glide Toggle
-- @author Yumyoo
-- @version 1.0
-- @about Converts overlapping MIDI notes into FL Studio-style pitch bends. Features monophonic voice-stealing, ghost automation wiping, and a Global Safety Net for new notes.

local editor = reaper.MIDIEditor_GetActive()
if not editor then return end

local take = reaper.MIDIEditor_GetTake(editor)
if not take then return end

local PB_RANGE = 12 

reaper.Undo_BeginBlock()

local function find_base_note(ignore_idx, g_start)
    local i = 0
    local best_idx = -1
    local best_start = -1
    while true do
        local p_ret, p_sel, p_muted, p_start, p_end, p_chan, p_pitch, p_vel = reaper.MIDI_GetNote(take, i)
        if not p_ret then break end
        
        if i ~= ignore_idx then
            if (p_chan == 0 or p_chan == 1) and not p_muted then
                if p_start <= g_start and p_end > g_start then
                    if p_start > best_start then
                        best_start = p_start
                        best_idx = i
                    end
                end
            end
        end
        i = i + 1
    end
    return best_idx
end

local sel_notes = {}
local i = -1
while true do
    i = reaper.MIDI_EnumSelNotes(take, i)
    if i == -1 then break end
    table.insert(sel_notes, i)
end

local bases_to_rebuild = {}
local toggled_off_notes = {}

for _, note_idx in ipairs(sel_notes) do
    local ret, sel, muted, startppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, note_idx)
    local base_idx = find_base_note(note_idx, startppq)
    
    if base_idx ~= -1 then
        local b_ret, b_sel, b_muted, b_start, b_end, b_chan, b_pitch, b_vel = reaper.MIDI_GetNote(take, base_idx)
        
        -- SURGICAL CHORD DECOUPLE FIX
        -- Scan for ANY normal note that shares this exact pitch and end time to prevent Note-Off merging
        local conflict_notes = {}
        local c_idx = 0
        while true do
            local c_ret, c_sel, c_muted, c_start, c_end, c_chan, c_pitch, c_vel = reaper.MIDI_GetNote(take, c_idx)
            if not c_ret then break end
            if c_idx ~= note_idx and (c_chan == 0 or c_chan == 1) and c_end == endppq and c_pitch == pitch then
                table.insert(conflict_notes, c_idx)
            end
            c_idx = c_idx + 1
        end
        
        -- Temporarily shrink all conflicting notes by 1 tick
        for _, c in ipairs(conflict_notes) do
            reaper.MIDI_SetNote(take, c, nil, nil, nil, endppq - 1, nil, nil, nil, true)
        end
        
        if chan == 0 or chan == 1 then
            reaper.MIDI_SetNote(take, note_idx, true, true, startppq, endppq, 2, pitch, vel, true)
            bases_to_rebuild[base_idx] = {start=b_start, endppq=b_end, chan=b_chan, pitch=b_pitch}
        elseif chan == 2 then
            reaper.MIDI_SetNote(take, note_idx, true, false, startppq, endppq, b_chan, pitch, vel, true)
            bases_to_rebuild[base_idx] = {start=b_start, endppq=b_end, chan=b_chan, pitch=b_pitch}
            toggled_off_notes[note_idx] = true
        end
        
        -- Instantly restore conflicting notes to their true length
        for _, c in ipairs(conflict_notes) do
            reaper.MIDI_SetNote(take, c, nil, nil, nil, endppq, nil, nil, nil, true)
        end
    end
end

local sorted_bases = {}
for b_idx, b_data in pairs(bases_to_rebuild) do
    table.insert(sorted_bases, {idx = b_idx, data = b_data})
end
table.sort(sorted_bases, function(a, b) return a.data.start < b.data.start end)

for _, base_item in ipairs(sorted_bases) do
    local b_data = base_item.data
    local base_idx = base_item.idx
    
    local glides = {}
    local k = 0
    while true do
        local ret, sel, muted, startppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, k)
        if not ret then break end
        
        if chan == 2 and startppq >= b_data.start and startppq < b_data.endppq then
            if find_base_note(k, startppq) == base_idx then
                table.insert(glides, {startppq=startppq, endppq=endppq, pitch=pitch})
            end
        end
        k = k + 1
    end

    local max_wipe = b_data.endppq
    for _, g in ipairs(glides) do
        if g.endppq > max_wipe then max_wipe = g.endppq end
    end
    
    local hold_ppq = max_wipe - 1 

    local next_base_start = math.huge
    local n_idx = 0
    while true do
        local ret, sel, muted, p_start, p_end, p_chan, p_pitch, p_vel = reaper.MIDI_GetNote(take, n_idx)
        if not ret then break end
        
        if (p_chan == 0 or p_chan == 1) and not muted and p_start >= b_data.endppq then
            if not toggled_off_notes[n_idx] then
                if p_start < next_base_start then next_base_start = p_start end
            end
        end
        n_idx = n_idx + 1
    end
    
    local wipe_end = max_wipe + 19200 
    if wipe_end >= next_base_start then wipe_end = next_base_start - 1 end
    
    if hold_ppq >= wipe_end then hold_ppq = wipe_end - 1 end

    local _, _, cc_count, _ = reaper.MIDI_CountEvts(take)
    for j = cc_count - 1, 0, -1 do
        local cc_ret, cc_sel, cc_muted, cc_ppq, cc_chanmsg, cc_chan = reaper.MIDI_GetCC(take, j)
        if cc_chanmsg == 224 and cc_chan == b_data.chan and cc_ppq >= b_data.start and cc_ppq <= wipe_end then
            reaper.MIDI_DeleteCC(take, j)
        end
    end

    if #glides > 0 then
        table.sort(glides, function(a, b) return a.startppq < b.startppq end)
        
        local current_pb = 8192
        local cc_events = {}
        
        table.insert(cc_events, {ppq = b_data.start, val = 8192, shape = 0})
        
        for idx, g in ipairs(glides) do
            if g.startppq <= hold_ppq then
                local diff = g.pitch - b_data.pitch
                if diff > PB_RANGE then diff = PB_RANGE end
                if diff < -PB_RANGE then diff = -PB_RANGE end
                local target_pb = 8192 + math.floor((diff / PB_RANGE) * 8191 + 0.5)
                
                local effective_end = g.endppq
                local interrupted = false
                
                if idx < #glides and glides[idx+1].startppq < g.endppq then
                    effective_end = glides[idx+1].startppq
                    interrupted = true
                end
                
                if effective_end > hold_ppq then effective_end = hold_ppq end
                
                table.insert(cc_events, {ppq = g.startppq, val = current_pb, shape = 1})
                
                if interrupted then
                    local duration = g.endppq - g.startppq
                    if duration > 0 then
                        local progress = (effective_end - g.startppq) / duration
                        current_pb = current_pb + math.floor((target_pb - current_pb) * progress + 0.5)
                    else
                        current_pb = target_pb
                    end
                else
                    current_pb = target_pb
                end
                
                if current_pb > 16383 then current_pb = 16383 end
                if current_pb < 0 then current_pb = 0 end
                
                table.insert(cc_events, {ppq = effective_end, val = current_pb, shape = 0})
            end
        end
        
        table.insert(cc_events, {ppq = hold_ppq, val = current_pb, shape = 0})
        table.insert(cc_events, {ppq = wipe_end, val = 8192, shape = 0})
        
        table.sort(cc_events, function(a, b) return a.ppq < b.ppq end)
        local clean_ccs = {}
        for _, evt in ipairs(cc_events) do
            if #clean_ccs > 0 and math.abs(clean_ccs[#clean_ccs].ppq - evt.ppq) < 0.5 then
                if evt.shape == 1 then
                    clean_ccs[#clean_ccs] = evt 
                else
                    local old_shape = clean_ccs[#clean_ccs].shape
                    clean_ccs[#clean_ccs] = evt
                    if old_shape == 1 then clean_ccs[#clean_ccs].shape = 1 end
                end
            else
                table.insert(clean_ccs, evt)
            end
        end
        
        for _, evt in ipairs(clean_ccs) do
            local lsb = evt.val & 127
            local msb = (evt.val >> 7) & 127
            reaper.MIDI_InsertCC(take, false, false, evt.ppq, 224, b_data.chan, lsb, msb)
        end
        
        reaper.MIDI_Sort(take)
        local _, _, new_cc_count, _ = reaper.MIDI_CountEvts(take)
        for j = 0, new_cc_count - 1 do
            local cc_ret, cc_sel, cc_muted, cc_ppq, cc_chanmsg, cc_chan = reaper.MIDI_GetCC(take, j)
            if cc_chanmsg == 224 and cc_chan == b_data.chan and cc_ppq >= b_data.start and cc_ppq <= wipe_end then
                for _, evt in ipairs(clean_ccs) do
                    if math.abs(cc_ppq - evt.ppq) <= 2 then
                        reaper.MIDI_SetCCShape(take, j, evt.shape, 0)
                        break
                    end
                end
            end
        end
    end
end

-- GLOBAL SAFETY NET: Guarantees a pitch-reset anchor at the start of normal notes,
-- UNLESS a glide sweep is starting at that exact millisecond.
local note_idx = 0
local global_anchors = {}
while true do
    local ret, sel, muted, p_start, p_end, p_chan, p_pitch, p_vel = reaper.MIDI_GetNote(take, note_idx)
    if not ret then break end
    if (p_chan == 0 or p_chan == 1) and not muted then
        
        -- Collision Check: Is a glide starting at this exact tick?
        local conflict = false
        local g_idx = 0
        while true do
            local g_ret, g_sel, g_muted, g_start, g_end, g_chan = reaper.MIDI_GetNote(take, g_idx)
            if not g_ret then break end
            if g_chan == 2 and g_start == p_start then
                conflict = true
                break
            end
            g_idx = g_idx + 1
        end
        
        if not conflict then
            table.insert(global_anchors, {ppq = p_start, chan = p_chan})
        end
    end
    note_idx = note_idx + 1
end

for _, anchor in ipairs(global_anchors) do
    reaper.MIDI_InsertCC(take, false, false, anchor.ppq, 224, anchor.chan, 0, 64)
end

reaper.MIDI_Sort(take)

local _, _, total_cc_count, _ = reaper.MIDI_CountEvts(take)
for j = 0, total_cc_count - 1 do
    local cc_ret, cc_sel, cc_muted, cc_ppq, cc_chanmsg, cc_chan = reaper.MIDI_GetCC(take, j)
    if cc_chanmsg == 224 then
        for _, anchor in ipairs(global_anchors) do
            if cc_ppq == anchor.ppq and cc_chan == anchor.chan then
                reaper.MIDI_SetCCShape(take, j, 0, 0) 
            end
        end
    end
end

reaper.MIDI_Sort(take)
reaper.Undo_EndBlock("Toggle Yumyoo FL-Style Glide", -1)
