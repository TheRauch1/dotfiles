-- GitHub through the gh CLI: lua/config/gh.lua is the main UI (SPC g p),
-- mirroring doom/gh.el. octo.nvim is there for line-by-line review
-- comments (SPC g p o, or O in a PR buffer).
return {
  {
    "pwntester/octo.nvim",
    cmd = "Octo",
    dependencies = { "nvim-lua/plenary.nvim", "folke/snacks.nvim" },
    opts = {
      picker = "snacks",
      enable_builtin = true,
      default_merge_method = "squash",
      use_local_fs = false,
      suppress_missing_scope = { projects_v2 = true },
    },
  },
}
