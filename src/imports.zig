pub const c = @cImport({
    @cDefine("GLFW_INCLUDE_NONE", {});
    @cDefine("GLFW_INCLUDE_VULKAN", {});
    @cInclude("GLFW/glfw3.h");
});
