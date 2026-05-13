#version 460
#extension GL_EXT_buffer_reference : require
#extension GL_EXT_buffer_reference2 : require
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_shader_image_load_formatted : require
#extension GL_EXT_debug_printf : require
layout(set = 0, binding = 0) uniform texture2D _res_textures_[];
layout(set = 1, binding = 0) uniform image2D _res_textures_rw_[];
layout(set = 2, binding = 0) uniform sampler _res_samplers_[];


// Intrinsics:

#define texture_sample(t, s, uv)       texture(sampler2D(_res_textures_[nonuniformEXT(t)], _res_samplers_[nonuniformEXT(s)]), uv)
#define texture_load(t, coord)         imageLoad(_res_textures_rw_[nonuniformEXT(t)], ivec2(coord))
#define texture_store(t, coord, value) imageStore(_res_textures_rw_[nonuniformEXT(t)], ivec2(coord), value)
#define texture_size(t, s, lod)        textureSize(sampler2D(_res_textures_[nonuniformEXT(t)], _res_samplers_[nonuniformEXT(s)]), lod)
#define image_size(t)                  imageSize(_res_textures_rw_[nonuniformEXT(t)])

// Intrinsics end.

bool bool_ZERO;
int int_ZERO;
uint uint_ZERO;
float float_ZERO;
vec2 vec2_ZERO;
vec3 vec3_ZERO;
vec4 vec4_ZERO;
mat4 mat4_ZERO;
uint texture_id_ZERO;
uint sampler_id_ZERO;
uint bvh_id_ZERO;

layout(location = 1) out vec3 _res_out_loc1_;
layout(location = 2) out vec2 _res_out_loc2_;
layout(location = 0) out vec3 _res_out_loc0_;

layout(buffer_reference) readonly buffer _res_ptr_void;
layout(buffer_reference) readonly buffer _res_slice_vec3;
layout(buffer_reference) readonly buffer _res_slice_vec2;
layout(buffer_reference) readonly buffer _res_ptr_Data;

struct Output
{
    vec4 out_pos_;
    vec3 world_pos_;
    vec3 world_normal_;
    vec2 uv_;
};
Output Output_ZERO;
struct Data
{
    _res_slice_vec3 pos_;
    _res_slice_vec3 normals_;
    _res_slice_vec2 uvs_;
    _res_slice_vec2 lightmap_uvs_;
    vec2 resolution_;
    mat4 model_to_world_;
    mat4 model_to_world_normals_;
};
Data Data_ZERO;
void main();
layout(buffer_reference, scalar) readonly buffer _res_ptr_void { uint _res_void_; };
layout(buffer_reference, scalar) readonly buffer _res_slice_vec3 { vec3 _res_[]; };
_res_slice_vec3 _res_slice_vec3_ZERO;
layout(buffer_reference, scalar) readonly buffer _res_slice_vec2 { vec2 _res_[]; };
_res_slice_vec2 _res_slice_vec2_ZERO;
layout(buffer_reference, scalar) readonly buffer _res_ptr_Data { Data _res_; };
_res_ptr_Data _res_ptr_Data_ZERO;
struct _res_array_25_vec2 { vec2 data[25]; };
_res_array_25_vec2 _res_array_25_vec2_ZERO;

layout(push_constant, scalar) uniform Push
{
    _res_ptr_Data _res_vert_data_;
    _res_ptr_Data _res_frag_data_;
    _res_ptr_void _res_indirect_data_;
};

void main()
{
    uint vert_id_ = gl_VertexIndex;
    uint instance_id_ = gl_InstanceIndex;
    _res_ptr_Data data_ = _res_vert_data_;
    _res_array_25_vec2 offsets_ = _res_array_25_vec2_ZERO;
    vec2 uv_offset_ = vec2_ZERO;
    vec2 ndc_offset_ = vec2_ZERO;
    Output vert_out_ = Output_ZERO;
    offsets_.data[0] = vec2((-2.0), (-2.0));
    offsets_.data[1] = vec2(2.0, (-2.0));
    offsets_.data[2] = vec2((-2.0), 2.0);
    offsets_.data[3] = vec2(2.0, 2.0);
    offsets_.data[4] = vec2((-1.0), (-2.0));
    offsets_.data[5] = vec2(1.0, (-2.0));
    offsets_.data[6] = vec2((-2.0), (-1.0));
    offsets_.data[7] = vec2(2.0, (-1.0));
    offsets_.data[8] = vec2((-2.0), 1.0);
    offsets_.data[9] = vec2(2.0, 1.0);
    offsets_.data[10] = vec2((-1.0), 2.0);
    offsets_.data[11] = vec2(1.0, 2.0);
    offsets_.data[12] = vec2((-2.0), 0.0);
    offsets_.data[13] = vec2(2.0, 0.0);
    offsets_.data[14] = vec2(0.0, (-2.0));
    offsets_.data[15] = vec2(0.0, 2.0);
    offsets_.data[16] = vec2((-1.0), (-1.0));
    offsets_.data[17] = vec2(1.0, (-1.0));
    offsets_.data[18] = vec2((-1.0), 0.0);
    offsets_.data[19] = vec2(1.0, 0.0);
    offsets_.data[20] = vec2((-1.0), 1.0);
    offsets_.data[21] = vec2(1.0, 1.0);
    offsets_.data[22] = vec2(0.0, (-1.0));
    offsets_.data[23] = vec2(0.0, 1.0);
    offsets_.data[24] = vec2(0.0, 0.0);
    uv_offset_ = offsets_.data[(instance_id_ % 25)];
    ndc_offset_ = ((uv_offset_ / data_._res_.resolution_) / 2.0);
    vert_out_.out_pos_ = vec4((((data_._res_.lightmap_uvs_._res_[vert_id_] * 2) - 1) + ndc_offset_), 0, 1);
    vert_out_.world_pos_ = (data_._res_.model_to_world_ * vec4(data_._res_.pos_._res_[vert_id_], 1)).xyz;
    vert_out_.world_normal_ = (data_._res_.model_to_world_normals_ * vec4(data_._res_.normals_._res_[vert_id_], 0)).xyz;
    vert_out_.uv_ = data_._res_.uvs_._res_[vert_id_];
    gl_Position = vert_out_.out_pos_; _res_out_loc0_ = vert_out_.world_pos_; _res_out_loc1_ = vert_out_.world_normal_; _res_out_loc2_ = vert_out_.uv_; 
}

