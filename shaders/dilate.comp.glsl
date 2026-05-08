#version 460
#extension GL_EXT_buffer_reference : require
#extension GL_EXT_buffer_reference2 : require
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_shader_image_load_formatted : require
#extension GL_EXT_debug_printf : require
layout(local_size_x_id = 13370, local_size_y_id = 13371, local_size_z_id = 13372) in;
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


layout(buffer_reference) readonly buffer _res_ptr_void;
layout(buffer_reference) readonly buffer _res_ptr_Data;

struct Data
{
    uint output_;
    uint input_;
};
Data Data_ZERO;
void main();
layout(buffer_reference, scalar) readonly buffer _res_ptr_void { uint _res_void_; };
layout(buffer_reference, scalar) readonly buffer _res_ptr_Data { Data _res_; };
_res_ptr_Data _res_ptr_Data_ZERO;

layout(push_constant, scalar) uniform Push
{
    _res_ptr_Data _res_compute_data_;
};

void main()
{
    _res_ptr_Data data_ = _res_compute_data_;
    vec3 gid3_ = gl_GlobalInvocationID;
    vec2 gid_ = vec2_ZERO;
    vec2 tex_size_ = vec2_ZERO;
    vec4 src_color_ = vec4_ZERO;
    vec3 sample_sum_ = vec3_ZERO;
    uint sample_count_ = uint_ZERO;
    gid_ = gid3_.xy;
    tex_size_ = min(image_size(data_._res_.output_), image_size(data_._res_.input_));
    if(((((gid_.x < 0) || (gid_.x >= tex_size_.x)) || (gid_.y < 0)) || (gid_.y >= tex_size_.y)))
    {
        return ;
    }

    src_color_ = texture_load(data_._res_.input_, gid_);
    if((src_color_.a > 0.5))
    {
        texture_store(data_._res_.output_, gid_, src_color_);
        return ;
    }

    sample_sum_ = vec3(0);
    sample_count_ = 0;
    // for construct
    {
        int dy_;
        for(dy_ = (-1); (dy_ <= 1); dy_ += 1)
        {
            // for construct
            {
                int dx_;
                vec2 neighbor_coord_;
                vec4 neighbor_color_;
                for(dx_ = (-1); (dx_ <= 1); dx_ += 1)
                {
                    neighbor_coord_ = clamp((gid_ + vec2(float(dx_), float(dy_))), vec2(0), (tex_size_ - 1));
                    neighbor_color_ = texture_load(data_._res_.input_, neighbor_coord_);
                    if((neighbor_color_.a > 0.5))
                    {
                        sample_sum_ += neighbor_color_.rgb;
                        sample_count_ += 1;
                    }

                }
            }

        }
    }

    if((sample_count_ > 0))
    {
        texture_store(data_._res_.output_, gid_, vec4((sample_sum_ / float(sample_count_)), 1));
    }
    else
    {
        texture_store(data_._res_.output_, gid_, src_color_);
texture_store(data_._res_.output_, gid_, src_color_);    }

}

