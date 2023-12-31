-- SPDX-License-Identifier: MIT
--[[
MIT License

Copyright (c) 2023 gcask <53709079+gcask@users.noreply.github.com>

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
--]]

--[[
    Allow interpreting map markers as commands, as seen on some other servers.
    A user (or controller, via LotATC), can create a mark with the following syntax:
        
        -some_command:some free form arguments
        -argumentlessCommand
    
    If the command is accepted and processed, the mark is removed from the map.

    The argument `some free form arguments` are passed
    as a single string.

    The script has no dependencies.

USAGE
=====
    * Add the script to your miz via a MISSION START trigger.
    * Then use the sample below to set it up:
    ```
    local markCommander = MarkCommands:new()
    markCommander:register('echo', function(arg)
        -- simply parrot the text string.
        trigger.action.outText(arg, 5)
        -- Always succeeds.
        return true
    )

    markCommander:register('toggleFlag', function(flag)
        trigger.action.setUserFlag(flag, not trigger.action.getUserFlag(flag))
    end)

    -- Register the handler and start listening for events.
    markCommander:start()
    ```
    * A Mark object, as described here: https://wiki.hoggitworld.com/view/DCS_event_mark_change
      (minus the id) is passed as a second argument, should you need any information
      that are coming from the mark (ie coalition/group), if available.

CHANGELOG
=========

2023.12.30
----------
    Initial release.
--]]

MarkCommands = {
    new = function(self)
        local instance = { commands = {} }
        setmetatable(instance, self)
        self.__index = self

        return instance
    end,

    register = function(self, name, func)
        self.commands[name:lower()] = func
    end,

    unregister = function(self, name)
        self.commands[name:lower()] = nil
    end,

    start = function(self)
        world.addEventHandler(self)
    end,

    stop = function(self)
        wold.removeEventHandler(self)
    end,


    onEvent = function(self, event)
        if event.id ~= world.event.S_EVENT_MARK_ADDED and event.id ~= world.event.S_EVENT_MARK_CHANGE then
            return
        end

        -- Check well-formed:
        -- * must start with a -
        local command = event.text:match("^-([%w_]+)")
        if command == nil then
            env.info('Marks commander: not a command '..event.text)
            return
        end

        -- argument (if any) is separated by a :
        -- No funny business (no extra spaces, etc).
        local optionalArgument = event.text:sub(#command + 2):match("^:(.+)")
        if #event.text > #command and optionalArgument == nil then
            env.info('Marks commander: malformed '..event.text)
            return
        end

        local maybeCommand = self.commands[command:lower()]
        if maybeCommand == nil then
            env.info('Marks commander: unrecognized '..event.text)
            return
        end

        local runInfo = 'Marks commander: executing ' .. command:lower() .. '(' 
        if optionalArgument ~= nil then
            runInfo = runInfo .. optionalArgument
        end
        runInfo .. ')'
        env.info(runInfo)
        
        local mark = {
            idx = event.idx,
            time = event.time,
            initiator = event.initiator,
            coalition = event.coalition,
            groupID = event.groupID,
            pos = event.pos
        }

        timer.scheduleFunction(
            function(args)
                if args.command.func(args.command.argument, args.mark) then
                    trigger.action.removeMark(args.mark.id)
                end

                return nil
            end
            , { command = { func = maybeCommand, argument = optionalArgument }, mark = mark }
            , timer.getTime() + 1
        )
    end
}
