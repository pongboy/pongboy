-- Kernel Lua do Nibble

-- Para acessar as funções do kernel cpp
local hw = require('frameworks.kernel.hw')

-- Utilitários
local audio = require('frameworks.kernel.audio')
local input = require('frameworks.kernel.input')
local lang = require('frameworks.kernel.lang')
local gpu = require('frameworks.kernel.gpu')
local pprint = require('frameworks.kernel.pprint')

local processes = {}
local pid_counter = 0
local executing_process = nil

--
-- Pontos de entrada a partir do cpp
-- 

function init()
    processes[0] = make_process('apps/system/init.nib', {})
end

function update(dt)
    exec_processes(dt)
end

function audio_tick()
    for p, proc in pairs(processes) do
        if proc.priv.running then
            exec_audio_tick(proc)
        end
    end
end

function menu()
    pid_counter += 1

    processes[pid_counter] = make_process('apps/system/menu.nib', {
        pid = 0,
        app = {
            pid = pid_counter
        }
    })
end

--
-- Gerenciamento de processos
--

-- Cria um processo, composto de um conjunto
-- de infromações acessíveis apenas ao kernel
-- e um conjunto de informações públicsa ao código
-- do processo
function make_process(entrypoint, env)
    local proc = {}

    local sheet = entrypoint..'/assets/sheet.png'

    local sheet_ptr, sheet_w, sheet_h = hw.load_spritesheet(sheet)

    proc.priv = {
        spritesheet = {
            ptr = sheet_ptr,
            w = sheet_w,
            h = sheet_h
        },
        message_queue = {},
        pid = pid_counter,
        parent = executing_process,
    }

    proc.pub = nib_api(entrypoint, proc)
    proc.pub.env = env

    proc.priv.ok, err = exec(entrypoint..'/main.lua', proc.pub)
    proc.priv.running = true

    if not proc.priv.ok then
        print(err)
    end

    -- Põe as funções que vamos chamar em sandboxes
    sandbox_fn(proc.pub.init, proc.pub)
    sandbox_fn(proc.pub.draw, proc.pub)
    sandbox_fn(proc.pub.update, proc.pub)

    return proc
end

function exec_processes(dt)
    for p, proc in pairs(processes) do
        if proc.priv.running then
            exec_process(proc, dt)
        end
    end
end

function exec_process(process, dt)
    if not process.priv.ok then
        return
    end

    executing_process = process

    -- Usa a spritesheet do processo
    local sheet = process.priv.spritesheet
    hw.use_spritesheet(sheet.ptr, sheet.w, sheet.h)

    -- TODO: Coletar erros das chamadas?
    if process.priv.initialized then
        if process.pub.update then
            xpcall(process.pub.update, function (err)
                process.priv.ok = false
                handle_process_error(err)
            end, dt)
        end

        if process.pub.draw then
            xpcall(process.pub.draw, function (err)
                process.priv.ok = false
                handle_process_error(err)
            end)
        end
    else
        if process.pub.init then
            xpcall(process.pub.init, function (err)
                process.priv.ok = false
                handle_process_error(err)
            end)
        end

        process.priv.initialized = true
    end
end

function exec_audio_tick(process)
    if not process.priv.ok then
        return
    end

    executing_process = process

    -- Usa a spritesheet do processo
    local sheet = process.priv.spritesheet
    hw.use_spritesheet(sheet.ptr, sheet.w, sheet.h)

    if process.priv.initialized then
        if process.pub.audio_tick then
            xpcall(process.pub.audio_tick, function (err)
                process.priv.ok = false
                handle_process_error(err)
            end)
        end
    end
end

function exec(path, env, args)
    local fn, msg = loadfile(path)

    if not fn then
       return nil, msg
    end

    return exec_fn(fn, env, args)
end

function sandbox_fn(fn, env)
    if not fn then
        return
    end

    setfenv(fn, env)
end

function exec_fn(fn, env, args)
    setfenv(fn, env)

    return pcall(fn, args)
end

--
-- Funções customizadas para processos sandboxed
--

function nib_require(entrypoint, module, proc)
    local paths = {
        entrypoint..'/'..module:gsub("%.", "/")..'.lua',
        'frameworks/'..module:gsub("%.", "/")..'.lua',
    }

    local errors = {}

    for _, path in ipairs(paths) do
        local fn, err = loadfile(path)

        if not fn then
            table.insert(errors, 'require "'..path..'"): '..err)
        else
            sandbox_fn(fn, proc.pub)
            return fn()
        end
    end

    print('could not load', module, 'tried:')
    for _, err in ipairs(errors) do
        print(err)
    end
end

function handle_process_error(error)
    print(error)
    print(debug.traceback())
end

function nib_api(entrypoint, proc)
    return {
        -- Processos podem usar require limitado,
        require = function(module)
            return nib_require(entrypoint, module, proc)
        end,
        -- Permite escrever para stdout
        terminal_print = print,
        terminal_pretty = pprint,
        -- Syscalls
        start_app = function(app, env)
            pid_counter += 1
            processes[pid_counter] = make_process(app, env)
            return pid_counter, ''
        end,
        stop_app = function(pid)
            if pid == 0 then
                -- TODO: limpar a memória alocada pelo processo
                processes[executing_process.priv.pid] = nil
            else
                local process = processes[pid]

                if process and process.priv.parent == executing_process then
                    -- TODO: limpar a memória alocada pelo processo
                    processes[pid] = nil
                end
            end
        end,
        send_message = function(pid, message)
            if processes[pid] and message then
                table.insert(processes[pid].priv.message_queue, 1, message)
            end
        end,
        receive_message = function()
            return table.remove(executing_process.priv.message_queue)
        end,
        send_system_message = function(pid, message)
            local process = processes[pid]

            if process then
                if message == 'play' then
                    process.priv.running = true
                    table.insert(process.priv.message_queue, 1, {resume = true})
                elseif message == 'pause' then
                    process.priv.running = false
                end
            end
        end,
        -- Ferramentas para a linguagem
        instanceof = lang.instanceof,
        copy = lang.copy,
        zip = lang.zip,
        -- Funções matemática
        math = math,
        -- Funções gerais
        clock = os.clock,
        ipairs = ipairs, next = next, type = type,
        setmetatable = setmetatable, pairs = pairs, rawget = rawget,
        tonumber = tonumber, tostring = tostring,
        push = function (t, el) table.insert(t, 1, el) end,
        pop = table.remove,
        remove = table.remove,
        insert = table.insert,
        -- GPU
        clear = hw.clr,
        sprite = hw.spr,
        custom_sprite = hw.pspr,
        fill_rect = hw.rect_fill,
        fill_circ = hw.circle_fill,
        fill_tri = hw.tri_fill,
        fill_quad = hw.quad_fill,
        line = hw.line,
        rect = hw.rect,
        circ = hw.circle,
        tri = hw.tri,
        quad = hw.quad,
        clip = hw.clip,
        print = hw.print,
        start_capturing = hw.start_capturing,
        stop_capturing = hw.stop_capturing,
        -- Color manipulation
        copy_palette = gpu.copy_palette,
        mask_color = gpu.mask_color,
        swap_colors = gpu.swap_colors,
        swap_screen_colors = gpu.swap_screen_colors,
        rgba_color = hw.rgba_color,
        -- Memory access
        read16 = hw.read16,
        read8 = hw.read8,
        read = hw.read,
        write = hw.write,
        -- Input
        UP = input.UP,
        DOWN = input.DOWN,
        LEFT = input.LEFT,
        RIGHT = input.RIGHT,
        RED = input.RED,
        BLUE = input.BLUE,
        BLACK = input.BLACK,
        WHITE = input.WHITE,
        MOUSE_LEFT = input.MOUSE_LEFT,
        MOUSE_RIGHT = input.MOUSE_RIGHT,
        button_down = input.button_down,
        button_up = input.button_up,
        button_press = input.button_press,
        button_release = input.button_release,
        mouse_button_down = input.mouse_button_down,
        mouse_button_up = input.mouse_button_up,
        mouse_button_press = input.mouse_button_press,
        mouse_button_release = input.mouse_button_release,
        mouse_position = input.mouse_position,
        read_keys = input.read_keys,
        -- Sistema de arquivos
        list_directory = hw.list,
        -- Audio
        encode = audio.encode,
        channel = audio.channel,
        envelope = audio.envelope,
        freqs = audio.freqs,
        reverb = audio.reverb,
        route = audio.route,
        noteon = audio.noteon,
        noteoff = audio.noteoff,
        OP1 = audio.OP1,
        OP2 = audio.OP2,
        OP3 = audio.OP3,
        OP4 = audio.OP4,
        OUT = audio.OUT,
        CH1 = audio.CH1,
        CH2 = audio.CH2,
        CH3 = audio.CH3,
        CH4 = audio.CH4,
        CH5 = audio.CH5,
        CH6 = audio.CH6,
        CH7 = audio.CH7,
        CH8 = audio.CH8,
    }
end
