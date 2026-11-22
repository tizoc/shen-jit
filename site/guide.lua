-- How the guide and the documents rendered with it reach site/template.html. Pandoc has no grammar
-- for Shen, so this marks what the page colours itself: a transcript's prompts and output, and
-- comments. It also gives each document's page its title, and points links at the pages.

-- The documents with a page, and how a link that only names one reads there.
local PAGES = {
  design = 'How Shen/JIT works',
  semantics = 'Shen/JIT semantics',
  bytecode = 'Shen/JIT instructions and frames',
  ffi = 'Calling C',
  performance = 'Writing fast programs',
  structs = 'Managed structs',
  modules = 'Modules',
  numbers = 'Numbers by kind',
  floats = 'Arrays of doubles',
  word = '64-bit words',
  words = 'Arrays of words',
  option = 'Optional values',
  result = 'Results',
  buffers = 'Buffers and cursors',
  bytes = 'Byte scans and conversions',
  layout = 'Binary layouts',
  grammar = 'Grammars over bytes',
  io = 'Chunk I/O',
  fs = 'Filesystem operations',
  processes = 'Subprocesses and pipelines',
  parallel = 'Parallel map',
  ['tree-sitter'] = 'Tree-sitter bindings',
  framing = 'Binary framing',
  git = 'Local Git repositories',
  hyperloglog = 'HyperLogLog++ sketches',
  ['io-sockets'] = 'Socket I/O endpoints',
  ['networking'] = 'Networking',
  ['net-udp'] = 'In-memory IPv4 and UDP',
  ['net-tcp'] = 'In-memory TCP',
  ['net-tun'] = 'Linux TUN and TAP packet I/O',
  deadlines = 'Operation deadlines',
  ['http-head'] = 'HTTP head framing',
  http = 'HTTP requests and responses',
  ['http-streaming'] = 'Streaming HTTP responses',
  ['http-listener'] = 'HTTP servers',
  json = 'JSON',
  datalog = 'Datalog',
  curl = 'HTTP clients with libcurl',
}
local GROUPS = {
  { label = 'Internals & performance', pages = { 'design', 'semantics', 'bytecode', 'performance', 'ffi' } },
  { label = 'Language & types', pages = { 'structs', 'modules', 'numbers', 'floats', 'word', 'words', 'option', 'result' } },
  { label = 'Bytes & parsing', pages = { 'buffers', 'bytes', 'layout', 'grammar', 'json', 'tree-sitter' } },
  { label = 'I/O & systems', pages = { 'io', 'framing', 'deadlines', 'fs', 'processes', 'io-sockets', 'parallel' } },
  { label = 'Networking', pages = { 'networking', 'net-udp', 'net-tcp', 'net-tun' } },
  { label = 'HTTP', pages = { 'http-head', 'http', 'http-streaming', 'http-listener', 'curl' } },
  { label = 'Data & Git', pages = { 'datalog', 'hyperloglog', 'git' } },
}
local REPOSITORY = 'https://github.com/tizoc/shen-jit/blob/main/'

local function escape(text)
  return (text:gsub('[&<>]', { ['&'] = '&amp;', ['<'] = '&lt;', ['>'] = '&gt;' }))
end

-- A link to a document with a page goes there, the guide's being index.html, and any other into the
-- repository goes to GitHub, as the page is not next to it. A document's own links are relative to
-- docs/, and the guide's are to GitHub, so that each also works where it is read in the repository.
function Link(link)
  local path, fragment = link.target:match('^([^#]*)(#?.*)$')
  if path == '' then return nil end
  if path:sub(1, #REPOSITORY) == REPOSITORY then
    path = path:sub(#REPOSITORY + 1)
  elseif path:match('^%a[%w+.-]*:') then
    return nil
  elseif path:sub(1, 3) == '../' then
    path = path:sub(4)
  else
    path = 'docs/' .. path
  end
  local page = path:match('^docs/([%w-]+)%.md$')
  if page == 'guide' then
    link.target = 'index.html' .. fragment
  elseif page and PAGES[page] then
    link.target = page .. '.html' .. fragment
    local text = pandoc.utils.stringify(link.content)
    if text == page .. '.md' or text == path then
      link.content = { pandoc.Str(PAGES[page]) }
    end
  else
    link.target = REPOSITORY .. path .. fragment
  end
  return link
end

-- Sibling pages in the same topic group, for the contents rail of a document page.
local function group_nav(page)
  for _, group in ipairs(GROUPS) do
    local found = false
    for _, slug in ipairs(group.pages) do
      if slug == page then found = true; break end
    end
    if found then
      local items = {}
      for _, slug in ipairs(group.pages) do
        local cls = slug == page and ' class="here"' or ''
        items[#items + 1] = '<li><a' .. cls .. ' href="' .. slug .. '.html">' .. escape(PAGES[slug]) .. '</a></li>'
      end
      return '<div class="siblings"><p class="group-label">' .. escape(group.label) .. '</p><ul>'
        .. table.concat(items, '') .. '</ul></div>'
    end
  end
  return nil
end

-- A document's first heading is its page's title, as the guide's already is. In the page, the
-- slash in the name is in the logo's colour.
local function with_slash(inlines)
  local out = pandoc.List()
  for _, inline in ipairs(inlines) do
    if inline.t == 'Str' and inline.text == 'Shen/JIT' then
      out:insert(pandoc.Str('Shen'))
      out:insert(pandoc.RawInline('html', '<i>/</i>'))
      out:insert(pandoc.Str('JIT'))
    else
      out:insert(inline)
    end
  end
  return out
end

function Pandoc(doc)
  local first = doc.blocks[1]
  if not doc.meta.title and first and first.t == 'Header' then
    doc.meta.title = pandoc.MetaInlines(first.content)
    doc.blocks:remove(1)
  end
  doc.meta.pagetitle = pandoc.utils.stringify(doc.meta.title)
  doc.meta.title = pandoc.MetaInlines(with_slash(doc.meta.title))
  if doc.meta.page then
    local html = group_nav(pandoc.utils.stringify(doc.meta.page))
    if html then
      doc.meta.siblings = pandoc.MetaBlocks({ pandoc.RawBlock('html', html) })
    end
  end
  return doc
end

local function span(class, text)
  return '<span class="' .. class .. '">' .. escape(text) .. '</span>'
end

local function transcript(line)
  local prompt, rest = line:match('^(%(%d+[-+]%))(.*)$')
  if prompt then return span('p', prompt) .. escape(rest) end
  if line == '' then return '' end
  return span('o', line)
end

local function comments(pattern)
  return function(line)
    local code, comment = line:match('^(.-)(' .. pattern .. '.*)$')
    if code then return escape(code) .. span('c', comment) end
    return escape(line)
  end
end

local marks = {
  repl = transcript,
  sh = comments('%f[%S]#'),
  shen = comments('\\\\'),
}

function CodeBlock(block)
  local mark = marks[block.classes[1]] or escape
  local lines = {}
  for line in (block.text .. '\n'):gmatch('(.-)\n') do
    lines[#lines + 1] = mark(line)
  end
  return pandoc.RawBlock('html', '<pre><code>' .. table.concat(lines, '\n') .. '</code></pre>')
end

-- A wide table scrolls by itself, not the page.
function Table(wide)
  return pandoc.Div({ wide }, pandoc.Attr('', { 'wide' }))
end
