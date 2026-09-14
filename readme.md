
# lightmapper_rt

WIP.

## API Usage

```odin
// --- Initialize no_gfx context for lightmapper_rt
gpu.vk_add_opt_device_extension(vk.KHR_EXTERNAL_MEMORY_EXTENSION_NAME)
gpu.vk_add_opt_device_extension(vk.KHR_EXTERNAL_MEMORY_WIN32_EXTENSION_NAME)
gpu.vk_add_opt_device_extension(vk.KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME)
gpu.vk_add_opt_device_extension(vk.KHR_EXTERNAL_SEMAPHORE_EXTENSION_NAME)
gpu.vk_add_opt_device_extension(vk.KHR_EXTERNAL_SEMAPHORE_WIN32_EXTENSION_NAME)
gpu.vk_add_opt_device_extension(vk.KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME)
ok := gpu.init()
ensure(ok)
defer gpu.cleanup()

// --- Create the lightmap texture
lightmap := gpu.texture_alloc_and_create({
    format = .RGBA16_Float,
    dimensions = { LM_SIZE, LM_SIZE, 1 },
    usage = { .Sampled, .Storage, .Transfer_Src, .Color_Attachment }
})
defer gpu.texture_free_and_destroy(&lightmap)

lm_instances := /* Convert your scene into []lm.Instance */

// You can have multiple bake instances for different parts of your scene.
// Each bake instance will have a separate lightmap texture associated to it.
bake := lm.bake_begin(&lm_ctx, LM_SIZE, 3000, lightmap)
defer lm.bake_destroy(&bake)

// --- Main loop
for true
{
    // Per-frame operations...

    scene_has_changed := /* Detect if your instances have changed */
    if !bake.has_scene || scene_has_changed
    {
        lm_instances := /* Convert your scene into []lm.Instance */
        lm.bake_submit_scene(&bake, lm_instances)
        lm.bake_reset(&bake)
    }
    lights_have_changed := /* Detect if your lights have changed */
    if !bake.has_lights || lights_have_changed
    {
        lm_lights := /* Convert your lights into lm.Lights */
        lm.bake_submit_lights(&bake, lm_lights)
        lm.bake_reset(&bake)
    }
    lm.bake_iteration(&bake, frame_arena, do_denoise)

    fmt.printfln("Bake progress: %v%%", lm.bake_progress(&bake))
}

gpu.wait_idle()
```

TODO:
- Would be nice if charts were cached to disk in these tests...
- Fix API things and update BVH
- Lightmap_UVs_Handle should not be a thing
- Add lightmap creation proc
- Add options (rays per pixel, denoise tile size)
- Fix denoise things
- Find/make some nice scenes for social media points
