const std = @import("std");
const imports = @import("imports.zig");
const glfw = imports.glfw;
const mat4 = @import("zglm/mat4.zig");

pub fn main() !void {
    _ = glfw.glfwInit();

    _ = glfw.glfwWindowHint(glfw.GLFW_CLIENT_API, glfw.GLFW_NO_API);
    const window: *glfw.GLFWwindow = glfw.glfwCreateWindow(800, 600, "Vulkan Window", null, null) orelse {
        return error{couldnt_create_window}.couldnt_create_window;
    };

    var extensionCount: u32 = 0;
    _ = glfw.vkEnumerateInstanceExtensionProperties(null, &extensionCount, null);

    std.debug.print("{} extensions supported\n", .{extensionCount});

    while (glfw.glfwWindowShouldClose(window) == 0) {
        glfw.glfwPollEvents();
    }

    _ = glfw.glfwDestroyWindow(window);

    glfw.glfwTerminate();
}
