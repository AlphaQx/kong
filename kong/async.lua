local semaphore = require "ngx.semaphore"


local ngx = ngx
local kong = kong
local math = math
local pcall = pcall
local table = table
local select = select
local unpack = unpack
local setmetatable = setmetatable


local THREAD_COUNT = 100
local QUEUE_SIZE = 100000


local function thread(self, index)
  while not ngx.worker.exiting() do
    local ok, err = self.work:wait(1)
    if ok then
      if self.size > 0 then
        self.size = self.size - 1
        self.tail = self.tail == QUEUE_SIZE and 1 or self.tail + 1
        local tail = self.tail
        local job = self.jobs[tail]
        self.jobs[tail] = nil
        self.running = self.running + 1
        self.job_start_times[tail] = ngx.now() * 1000
        local pok, res, err_msg = job()
        self.job_end_times[tail] = ngx.now() * 1000
        self.running = self.running - 1
        if not pok then
          kong.log.err("async thread #", index, " job error: ", res)
        elseif not res and err_msg then
          kong.log.err("async thread #", index, " job returned an error: ", err_msg)
        end
      end

    elseif err ~= "timeout" then
      kong.log.err("async thread wait error: ", err)
    end

    local time = ngx.time()
    if time - self.time >= 60 then
      self.time = time
      if self.size <= 100 then
        kong.log.debug(self.size, " async jobs pending and ", self.running, " async jobs running")
      elseif self.size <= 1000 then
        kong.log.info(self.size, " async jobs pending and ", self.running, " async jobs running")
      elseif self.size <= 10000 then
        kong.log.notice(self.size, " async jobs pending and ", self.running, " async jobs running")
      elseif self.size <= 100000 then
        kong.log.warn(self.size, " async jobs pending and ", self.running, " async jobs running")
      else
        kong.log.err(self.size, " async jobs pending and ", self.running, " async jobs running")
      end
    end
  end

  return true
end


local function init_worker(premature, self)
  if premature then
    return true
  end

  local t = self.threads

  for i = 1, THREAD_COUNT do
    t[i] = ngx.thread.spawn(thread, self, i)
  end

  local ok, err = ngx.thread.wait(t[1],  t[2],  t[3],  t[4],  t[5],  t[6],  t[7],  t[8],  t[9],  t[10],
                                  t[11], t[12], t[13], t[14], t[15], t[16], t[17], t[18], t[19], t[20],
                                  t[21], t[22], t[23], t[24], t[25], t[26], t[27], t[28], t[29], t[30],
                                  t[31], t[32], t[33], t[34], t[35], t[36], t[37], t[38], t[39], t[40],
                                  t[41], t[42], t[43], t[44], t[45], t[46], t[47], t[48], t[49], t[50],
                                  t[51], t[52], t[53], t[54], t[55], t[56], t[57], t[58], t[59], t[60],
                                  t[61], t[62], t[63], t[64], t[65], t[66], t[67], t[68], t[69], t[70],
                                  t[71], t[72], t[73], t[74], t[75], t[76], t[77], t[78], t[79], t[80],
                                  t[81], t[82], t[83], t[84], t[85], t[86], t[87], t[88], t[89], t[90],
                                  t[91], t[92], t[93], t[94], t[95], t[96], t[97], t[98], t[99], t[100])

  if not ok then
    kong.log.err("async thread worker error: ", err)
  end

  for i = 1, THREAD_COUNT do
    ngx.thread.kill(t[i])
    t[i] = nil
  end

  return init_worker(ngx.worker.exiting(), self)
end


local function create_job(func, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, ...)
  local argc = select("#", ...)
  local args = argc > 0 and { ... }

  if not args then
    return function()
      return pcall(func, ngx.worker.exiting(), a1, a2, a3, a4, a5, a6, a7, a8, a9, a10)
    end
  end

  return function()
    return pcall(func, ngx.worker.exiting(), a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, unpack(args, 1, argc))
  end
end


local async = {}


async.__index = async


function async.new()
  local threads = kong.table.new(THREAD_COUNT, 0)
  local jobs = kong.table.new(QUEUE_SIZE, 0)
  local job_queue_times = kong.table.new(QUEUE_SIZE, 0)
  local job_start_times = kong.table.new(QUEUE_SIZE, 0)
  local job_end_times = kong.table.new(QUEUE_SIZE, 0)

  return setmetatable({
    threads = threads,
    jobs = jobs,
    job_queue_times = job_queue_times,
    job_start_times = job_start_times,
    job_end_times = job_end_times,
    work = semaphore.new(),
    running = 0,
    size = 0,
    head = 0,
    tail = 0,
    time = ngx.time(),
  }, async)
end


function async:init_worker()
  return ngx.timer.at(0, init_worker, self)
end


function async:run(func, ...)
  if self.size == QUEUE_SIZE then
    return nil, "async queue is full"
  end

  self.size = self.size + 1
  self.head = self.head == QUEUE_SIZE and 1 or self.head + 1
  self.jobs[self.head] = create_job(func, ...)
  self.job_queue_times[self.head] = ngx.now() * 1000
  self.work:post()

  return true
end


function async:stats()
  local max_latency
  local min_latency
  local avg_latency
  local med_latency
  local p95_latency
  local p99_latency
  local max_runtime
  local min_runtime
  local avg_runtime
  local med_runtime
  local p95_runtime
  local p99_runtime

  local count
  if self.reached then
    count = QUEUE_SIZE

  else
    count = #self.job_end_times
    if count == QUEUE_SIZE then
      self.reached = true
    end
  end

  ngx.log(ngx.ERR, count)

  if count == 1 then
    local queued  = self.job_queue_times[1]
    local started = self.job_start_times[1]
    local ended   = self.job_end_times[1]

    local latency = started - queued
    local runtime = ended - started

    max_latency = latency
    min_latency = latency
    avg_latency = latency
    med_latency = latency
    p95_latency = latency
    p99_latency = latency
    max_runtime = runtime
    min_runtime = runtime
    avg_runtime = runtime
    med_runtime = runtime
    p95_runtime = runtime
    p99_runtime = runtime

  elseif count > 1 then
    local tot_latency = 0
    local tot_runtime = 0

    local latencies = kong.table.new(count, 0)
    local runtimes  = kong.table.new(count, 0)

    for i = 1, count do
      local queued  = self.job_queue_times[i]
      local started = self.job_start_times[i]
      local ended   = self.job_end_times[i]

      local latency = started - queued
      tot_latency   = latency + tot_latency
      latencies[i]  = latency
      max_latency   = math.max(latency, max_latency or latency)
      min_latency   = math.min(latency, min_latency or latency)

      local runtime = ended - started
      tot_runtime   = runtime + tot_runtime
      runtimes[i]   = runtime
      max_runtime   = math.max(runtime, max_runtime or runtime)
      min_runtime   = math.min(runtime, min_runtime or runtime)
    end

    avg_latency = math.floor(tot_latency / count + 0.5)
    avg_runtime = math.floor(tot_runtime / count + 0.5)

    table.sort(latencies)
    table.sort(runtimes)

    local med_index = count / 2
    local p95_index = 0.95 * count
    local p99_index = 0.99 * count

    if med_index == math.floor(med_index) then
      med_latency = math.floor((latencies[med_index] + latencies[med_index + 1]) / 2 + 0.5)
      med_runtime = math.floor(( runtimes[med_index] +  runtimes[med_index + 1]) / 2 + 0.5)
    else
      med_index   = math.floor(med_index + 0.5)
      med_latency = latencies[med_index]
      med_runtime = runtimes[med_index]
    end

    if p95_index == math.floor(p95_index) then
      p95_latency = math.floor((latencies[p95_index] + latencies[p95_index + 1]) / 2 + 0.5)
      p95_runtime = math.floor(( runtimes[p95_index] +  runtimes[p95_index + 1]) / 2 + 0.5)

    else
      p95_index   = math.floor(p95_index + 0.5)
      p95_latency = latencies[p95_index]
      p95_runtime = runtimes[p95_index]
    end

    if p99_index == math.floor(p99_index) then
      p99_latency = math.floor((latencies[p99_index] + latencies[p99_index + 1]) / 2 + 0.5)
      p99_runtime = math.floor(( runtimes[p99_index] +  runtimes[p99_index + 1]) / 2 + 0.5)

    else
      p99_index   = math.floor(p99_index + 0.5)
      p99_latency = latencies[p99_index]
      p99_runtime = runtimes[p99_index]
    end
  end

  return {
    pending = self.size,
    running = self.running,
    latency = {
      avg = avg_latency or 0,
      med = med_latency or 0,
      p95 = p95_latency or 0,
      p99 = p99_latency or 0,
      max = max_latency or 0,
      min = min_latency or 0,
    },
    runtime = {
      avg = avg_runtime or 0,
      med = med_runtime or 0,
      p95 = p95_runtime or 0,
      p99 = p99_runtime or 0,
      max = max_runtime or 0,
      min = min_runtime or 0,
    },
  }
end


return async
