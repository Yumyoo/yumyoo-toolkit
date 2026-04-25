-- @description Yumyoo MIDI Phase Switch Toggle
-- @author Yumyoo
-- @version 1.0
-- @about Toggles selected MIDI notes between Channel 1 and Channel 2. Designed as the companion script for the Yumyoo MIDI Phase Switch JSFX plugin to trigger per-note audio polarity inversion.

local editor = reaper.MIDIEditor_GetActive()
if not editor then return end

local take = reaper.MIDIEditor_GetTake(editor)
if not take then return end

reaper.Undo_BeginBlock()

local i = -1
while true do
    i = reaper.MIDI_EnumSelNotes(take, i)
    if i == -1 then break end
    
    local retval, sel, muted, startppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
    
    -- In Reaper's backend, Channel 1 is 0, and Channel 2 is 1.
    local new_chan = 0
    if chan == 0 then
        new_chan = 1
    else
        new_chan = 0
    end
    
    reaper.MIDI_SetNote(take, i, sel, muted, startppq, endppq, new_chan, pitch, vel, true)
end

reaper.MIDI_Sort(take)
reaper.Undo_EndBlock("Toggle Yumyoo MIDI Phase Switch", -1)