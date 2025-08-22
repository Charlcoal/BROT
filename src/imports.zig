pub const c = @cImport({
    @cDefine("GLFW_INCLUDE_NONE", {});
    @cDefine("GLFW_INCLUDE_VULKAN", {});
    @cInclude("GLFW/glfw3.h");
    @cInclude("dcimgui.h");
    @cInclude("backends/dcimgui_impl_glfw.h");
    @cInclude("backends/dcimgui_impl_vulkan.h");
});
