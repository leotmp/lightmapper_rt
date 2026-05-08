#version 460
#extension GL_EXT_buffer_reference : require
#extension GL_EXT_buffer_reference2 : require
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_shader_image_load_formatted : require
#extension GL_EXT_debug_printf : require
#extension GL_EXT_ray_query : require
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


// Raytracing intrinsics:

layout(set = 3, binding = 0) uniform accelerationStructureEXT _res_bvhs_[];

mat4 _res_mat4_from_mat4x3(mat4x3 m)
{
    // GLSL is column-major: m[col][row]
    return mat4(
        vec4(m[0], 0.0),
        vec4(m[1], 0.0),
        vec4(m[2], 0.0),
        vec4(m[3], 1.0)
    );
}

struct Ray_Desc
{
    uint flags_;
    uint cull_mask_;
    float t_min_;
    float t_max_;
    vec3 origin_;
    vec3 dir_;
};
Ray_Desc Ray_Desc_ZERO;

struct Ray_Result
{
    uint kind_;
    float t_;
    uint instance_idx_;
    uint primitive_idx_;
    vec2 barycentrics_;
    bool front_face_;
    mat4 object_to_world_;
    mat4 world_to_object_;
};
Ray_Result Ray_Result_ZERO;

Ray_Result rayquery_result(rayQueryEXT rq)
{
    Ray_Result res;
    res.kind_ = rayQueryGetIntersectionTypeEXT(rq, true);
    res.t_ = rayQueryGetIntersectionTEXT(rq, true);
    res.instance_idx_  = rayQueryGetIntersectionInstanceIdEXT(rq, true);
    res.primitive_idx_ = rayQueryGetIntersectionPrimitiveIndexEXT(rq, true);
    res.front_face_    = rayQueryGetIntersectionFrontFaceEXT(rq, true);
    res.object_to_world_ = _res_mat4_from_mat4x3(rayQueryGetIntersectionObjectToWorldEXT(rq, true));
    res.world_to_object_ = _res_mat4_from_mat4x3(rayQueryGetIntersectionWorldToObjectEXT(rq, true));
    res.barycentrics_    = rayQueryGetIntersectionBarycentricsEXT(rq, true);
    return res;
}

Ray_Result rayquery_candidate(rayQueryEXT rq)
{
    Ray_Result res;
    res.kind_ = rayQueryGetIntersectionTypeEXT(rq, false);
    res.t_ = rayQueryGetIntersectionTEXT(rq, false);
    res.instance_idx_  = rayQueryGetIntersectionInstanceIdEXT(rq, false);
    res.primitive_idx_ = rayQueryGetIntersectionPrimitiveIndexEXT(rq, false);
    res.front_face_    = rayQueryGetIntersectionFrontFaceEXT(rq, false);
    res.object_to_world_ = _res_mat4_from_mat4x3(rayQueryGetIntersectionObjectToWorldEXT(rq, false));
    res.world_to_object_ = _res_mat4_from_mat4x3(rayQueryGetIntersectionWorldToObjectEXT(rq, false));
    res.barycentrics_    = rayQueryGetIntersectionBarycentricsEXT(rq, false);
    return res;
}

void rayquery_init(rayQueryEXT rq, Ray_Desc desc, uint bvh)
{
    rayQueryInitializeEXT(rq,
                          _res_bvhs_[nonuniformEXT(bvh)],
                          desc.flags_,
                          desc.cull_mask_,
                          desc.origin_,
                          desc.t_min_,
                          desc.dir_,
                          desc.t_max_);
}

bool rayquery_proceed(rayQueryEXT rq)
{
    return rayQueryProceedEXT(rq);
}

// Raytracing intrinsics end.

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
layout(buffer_reference) readonly buffer _res_slice_Instance;
layout(buffer_reference) readonly buffer _res_slice_Mesh;
layout(buffer_reference) readonly buffer _res_slice_vec3;
layout(buffer_reference) readonly buffer _res_slice_vec2;
layout(buffer_reference) readonly buffer _res_slice_uint;
layout(buffer_reference) readonly buffer _res_ptr_Data;

struct Lights
{
    vec3 dir_light_dir_;
    float dir_light_angle_;
    vec3 dir_light_emission_;
};
Lights Lights_ZERO;
struct Scene
{
    _res_slice_Instance instances_;
    _res_slice_Mesh meshes_;
    Lights lights_;
    uint _res_padding_0;
};
Scene Scene_ZERO;
struct Mesh
{
    _res_slice_vec3 pos_;
    _res_slice_vec3 normal_;
    _res_slice_vec2 uvs_;
    _res_slice_uint indices_;
};
Mesh Mesh_ZERO;
struct Instance
{
    uint mesh_idx_;
    uint albedo_tex_;
};
Instance Instance_ZERO;
struct Data
{
    uint output_texture_id_;
    uint tlas_;
    uint linear_sampler_;
    uint _res_padding_0;
    Scene scene_;
    vec2 resolution_;
    uint accum_counter_;
    bool is_lightmap_;
    mat4 camera_to_world_;
    uint gbufs_id_;
    uint _res_padding_1;
};
Data Data_ZERO;
struct Ray
{
    vec3 ori_;
    vec3 dir_;
};
Ray Ray_ZERO;
struct Hit_Info
{
    bool hit_;
    float t_;
    vec3 normal_;
    uint mesh_idx_;
    uint instance_idx_;
    uint tri_idx_;
    vec2 uv_;
};
Hit_Info Hit_Info_ZERO;
struct Material_Point
{
    vec3 color_;
};
Material_Point Material_Point_ZERO;
void main();
vec3 bake_texel(vec3 world_pos_, vec3 world_normal_, Scene scene_, uint tlas_, uint sampler_);
vec3 pathtrace(Ray start_ray_, Scene scene_, uint tlas_, uint sampler_);
Hit_Info ray_scene_intersection(Ray ray_, Scene scene_, uint tlas_);
Hit_Info ray_skip_alpha_stochastically(Ray start_ray_, Scene scene_, uint tlas_);
float get_alpha(Scene scene_, Hit_Info hit_);
uint hash_u32(uint seed_);
void init_rng(uint global_id_, uint accum_counter_);
uint random_u32();
float random_f32();
vec2 random_vec2();
float copysignf(float mag_, float sgn_);
mat4 basis_fromz(vec3 v_);
vec3 sample_hemisphere_cos(vec3 normal_, vec2 ruv_);
float sample_hemisphere_cos_pdf(vec3 normal_, vec3 direction_);
Material_Point get_material_point(Scene scene_, Hit_Info hit_);
vec3 sample_matte(vec3 normal_, vec2 rn_);
vec3 eval_matte(vec3 color_, vec3 normal_, vec3 incoming_);
float sample_matte_pdf(vec3 normal_, vec3 incoming_);
bool is_finite(vec3 v_);
float sun_disk_falloff(vec3 ray_dir_, vec3 sun_dir_, float angular_radius_);
vec3 sample_sun_direction(vec3 sun_dir_, float angular_radius_, vec2 u_);
float eval_sun_pdf(vec3 dir_, vec3 sun_dir_, float angular_radius_);
vec3 sample_lights(Lights lights_, vec3 pos_, vec3 normal_, vec3 outgoing_);
float sample_lights_pdf(Lights lights_, vec3 pos_, vec3 incoming_);
vec3 sample_sky_emission(vec3 dir_, Scene scene_);
vec3 clamp_radiance(vec3 radiance_);
float pi = 3.14159265359;
uint RNG_STATE;
layout(buffer_reference, scalar) readonly buffer _res_ptr_void { uint _res_void_; };
layout(buffer_reference, scalar) readonly buffer _res_slice_Instance { Instance _res_[]; };
_res_slice_Instance _res_slice_Instance_ZERO;
layout(buffer_reference, scalar) readonly buffer _res_slice_Mesh { Mesh _res_[]; };
_res_slice_Mesh _res_slice_Mesh_ZERO;
layout(buffer_reference, scalar) readonly buffer _res_slice_vec3 { vec3 _res_[]; };
_res_slice_vec3 _res_slice_vec3_ZERO;
layout(buffer_reference, scalar) readonly buffer _res_slice_vec2 { vec2 _res_[]; };
_res_slice_vec2 _res_slice_vec2_ZERO;
layout(buffer_reference, scalar) readonly buffer _res_slice_uint { uint _res_[]; };
_res_slice_uint _res_slice_uint_ZERO;
layout(buffer_reference, scalar) readonly buffer _res_ptr_Data { Data _res_; };
_res_ptr_Data _res_ptr_Data_ZERO;

layout(push_constant, scalar) uniform Push
{
    _res_ptr_Data _res_compute_data_;
};

void main()
{
    _res_ptr_Data data_ = _res_compute_data_;
    vec3 global_invocation_id_ = gl_GlobalInvocationID;
    vec3 color_ = vec3_ZERO;
    Ray start_ray_ = Ray_ZERO;
    vec2 uv_ = vec2_ZERO;
    vec2 coord_ = vec2_ZERO;
    vec3 world_camera_pos_ = vec3_ZERO;
    vec3 camera_lookat_ = vec3_ZERO;
    vec3 world_camera_lookat_ = vec3_ZERO;
    init_rng(uint(((global_invocation_id_.y * data_._res_.resolution_.x) + global_invocation_id_.x)), data_._res_.accum_counter_);
    if(data_._res_.is_lightmap_)
    {
        vec4 pos_sample_;
        vec4 normal_sample_;
        vec3 normal_;
        Ray start_ray_;
        if(((global_invocation_id_.x >= data_._res_.resolution_.x) || (global_invocation_id_.y >= data_._res_.resolution_.y)))
        {
            return ;
        }

        pos_sample_ = texture_load((data_._res_.gbufs_id_ + 0), global_invocation_id_.xy);
        normal_sample_ = texture_load((data_._res_.gbufs_id_ + 1), global_invocation_id_.xy);
        if((normal_sample_.a < 0.1))
        {
            texture_store(data_._res_.output_texture_id_, global_invocation_id_.xy, vec4(0));
            return ;
        }

        normal_ = normalize(((normal_sample_ * 2.0) - 1.0).xyz);
        start_ray_.ori_ = (pos_sample_.xyz + (normal_ * 0.0011));
        start_ray_.dir_ = (-normal_);
        color_ = bake_texel(pos_sample_.xyz, normal_, data_._res_.scene_, data_._res_.tlas_, data_._res_.linear_sampler_);
    }
    else
    {
        uv_ = (global_invocation_id_.xy / data_._res_.resolution_);
        coord_ = ((2.0 * uv_) - 1.0);
        coord_.y *= (-1.0);
        coord_ = (coord_ * tan((((90.0 * pi) / 180.0) / 2.0)));
        coord_.y = ((coord_.y * data_._res_.resolution_.y) / data_._res_.resolution_.x);
        world_camera_pos_ = (data_._res_.camera_to_world_ * vec4(0, 0, 0, 1)).xyz;
        camera_lookat_ = normalize(vec3(coord_, 1));
        world_camera_lookat_ = normalize((data_._res_.camera_to_world_ * vec4(camera_lookat_, 0.0))).xyz;
        start_ray_.ori_ = world_camera_pos_;
        start_ray_.dir_ = world_camera_lookat_;
        color_ = clamp_radiance(pathtrace(start_ray_, data_._res_.scene_, data_._res_.tlas_, data_._res_.linear_sampler_));
uv_ = (global_invocation_id_.xy / data_._res_.resolution_);coord_ = ((2.0 * uv_) - 1.0);coord_.y *= (-1.0);coord_ = (coord_ * tan((((90.0 * pi) / 180.0) / 2.0)));coord_.y = ((coord_.y * data_._res_.resolution_.y) / data_._res_.resolution_.x);world_camera_pos_ = (data_._res_.camera_to_world_ * vec4(0, 0, 0, 1)).xyz;camera_lookat_ = normalize(vec3(coord_, 1));world_camera_lookat_ = normalize((data_._res_.camera_to_world_ * vec4(camera_lookat_, 0.0))).xyz;start_ray_.ori_ = world_camera_pos_;start_ray_.dir_ = world_camera_lookat_;color_ = clamp_radiance(pathtrace(start_ray_, data_._res_.scene_, data_._res_.tlas_, data_._res_.linear_sampler_));    }

    if(((global_invocation_id_.x < data_._res_.resolution_.x) && (global_invocation_id_.y < data_._res_.resolution_.y)))
    {
        if((data_._res_.accum_counter_ > 1))
        {
            float weight_;
            vec3 prev_color_;
            weight_ = (1.0 / float(data_._res_.accum_counter_));
            prev_color_ = texture_load(data_._res_.output_texture_id_, global_invocation_id_.xy).xyz;
            color_ = ((prev_color_ * (1 - weight_)) + (color_ * weight_));
            color_ = max(color_, vec3(0, 0, 0));
        }

        texture_store(data_._res_.output_texture_id_, global_invocation_id_.xy, vec4(color_, 1));
    }

}

vec3 bake_texel(vec3 world_pos_, vec3 world_normal_, Scene scene_, uint tlas_, uint sampler_)
{
    int N_ = int_ZERO;
    vec3 accum_ = vec3_ZERO;
    vec3 origin_ = vec3_ZERO;
    N_ = 1;
    accum_ = vec3(0, 0, 0);
    origin_ = world_pos_;
    // for construct
    {
        int i_;
        float light_prob_;
        float bsdf_prob_;
        vec3 incoming_;
        float prob_;
        float cos_term_;
        float mis_weight_;
        Ray ray_;
        for(i_ = 0; (i_ < N_); i_ += 1)
        {
            light_prob_ = 0.5;
            bsdf_prob_ = 0.5;
            if((random_f32() < bsdf_prob_))
            {
                incoming_ = sample_matte(world_normal_, random_vec2());
            }
            else
            {
                incoming_ = sample_lights(scene_.lights_, origin_, world_normal_, world_normal_);
incoming_ = sample_lights(scene_.lights_, origin_, world_normal_, world_normal_);            }

            if((incoming_ == vec3(0, 0, 0)))
            {
                continue;
            }

            prob_ = ((bsdf_prob_ * sample_matte_pdf(world_normal_, incoming_)) + (light_prob_ * sample_lights_pdf(scene_.lights_, origin_, incoming_)));
            cos_term_ = max(0.0, dot(world_normal_, incoming_));
            mis_weight_ = (cos_term_ / prob_);
            ray_.ori_ = origin_;
            ray_.dir_ = incoming_;
            accum_ += clamp_radiance((pathtrace(ray_, scene_, tlas_, sampler_) * mis_weight_));
        }
    }

    return (accum_ / float(N_));
}

vec3 pathtrace(Ray start_ray_, Scene scene_, uint tlas_, uint sampler_)
{
    vec3 radiance_ = vec3_ZERO;
    vec3 weight_ = vec3_ZERO;
    Ray ray_ = Ray_ZERO;
    int max_bounces_ = int_ZERO;
    radiance_ = vec3(0, 0, 0);
    weight_ = vec3(1, 1, 1);
    ray_ = start_ray_;
    max_bounces_ = 5;
    // for construct
    {
        int bounce_;
        Hit_Info hit_;
        vec3 hit_pos_;
        Material_Point mat_point_;
        vec3 outgoing_;
        vec3 incoming_;
        for(bounce_ = 0; (bounce_ <= max_bounces_); bounce_ = (bounce_ + 1))
        {
            hit_ = ray_skip_alpha_stochastically(ray_, scene_, tlas_);
            if((!hit_.hit_))
            {
                vec3 emission_;
                emission_ = sample_sky_emission(ray_.dir_, scene_);
                radiance_ += (emission_ * weight_);
                break;
            }

            hit_pos_ = (ray_.ori_ + (ray_.dir_ * hit_.t_));
            mat_point_ = get_material_point(scene_, hit_);
            outgoing_ = (-ray_.dir_);
            {
                float light_prob_;
                float bsdf_prob_;
                float prob_;
                light_prob_ = 0.5;
                bsdf_prob_ = 0.5;
                if((random_f32() < bsdf_prob_))
                {
                    float rnd0_;
                    vec2 rnd1_;
                    rnd0_ = random_f32();
                    rnd1_ = random_vec2();
                    incoming_ = sample_matte(hit_.normal_, rnd1_);
                }
                else
                {
                    incoming_ = sample_lights(scene_.lights_, hit_pos_, hit_.normal_, outgoing_);
incoming_ = sample_lights(scene_.lights_, hit_pos_, hit_.normal_, outgoing_);                }

                if((incoming_ == vec3(0, 0, 0)))
                {
                    break;
                }

                prob_ = ((bsdf_prob_ * sample_matte_pdf(hit_.normal_, incoming_)) + (light_prob_ * sample_lights_pdf(scene_.lights_, hit_pos_, incoming_)));
                weight_ *= (eval_matte(mat_point_.color_, hit_.normal_, incoming_) / prob_);
            }

            ray_.ori_ = hit_pos_;
            ray_.dir_ = incoming_;
            if(((weight_ == vec3(0, 0, 0)) || (!is_finite(weight_))))
            {
                break;
            }

            if((bounce_ > 3))
            {
                float survive_prob_;
                survive_prob_ = min(0.99, max(weight_.x, max(weight_.y, weight_.z)));
                if((random_f32() >= survive_prob_))
                {
                    break;
                }

                weight_ = (weight_ / survive_prob_);
            }

        }
    }

    return radiance_;
}

Hit_Info ray_scene_intersection(Ray ray_, Scene scene_, uint tlas_)
{
    uint Ray_Flags_Opaque_ = uint_ZERO;
    uint Ray_Flags_Terminate_On_First_Hit_ = uint_ZERO;
    uint Ray_Flags_Skip_Closest_Hit_Shader_ = uint_ZERO;
    uint Ray_Result_Kind_Miss_ = uint_ZERO;
    uint Ray_Result_Kind_Hit_Mesh_ = uint_ZERO;
    uint Ray_Result_Kind_Hit_AABB_ = uint_ZERO;
    Hit_Info hit_info_ = Hit_Info_ZERO;
    Ray_Desc desc_ = Ray_Desc_ZERO;
    rayQueryEXT rq_;
    Ray_Result hit_ = Ray_Result_ZERO;
    Instance instance_ = Instance_ZERO;
    Mesh mesh_ = Mesh_ZERO;
    _res_slice_uint indices_ = _res_slice_uint_ZERO;
    uint base_idx_ = uint_ZERO;
    float w_ = float_ZERO;
    vec3 n0_ = vec3_ZERO;
    vec3 n1_ = vec3_ZERO;
    vec3 n2_ = vec3_ZERO;
    vec3 normal_ = vec3_ZERO;
    vec4 world_normal_ = vec4_ZERO;
    vec2 bary_ = vec2_ZERO;
    Ray_Flags_Opaque_ = 1;
    Ray_Flags_Terminate_On_First_Hit_ = 4;
    Ray_Flags_Skip_Closest_Hit_Shader_ = 8;
    Ray_Result_Kind_Miss_ = 0;
    Ray_Result_Kind_Hit_Mesh_ = 1;
    Ray_Result_Kind_Hit_AABB_ = 2;
    desc_.flags_ = Ray_Flags_Opaque_;
    desc_.cull_mask_ = 0xFF;
    desc_.t_min_ = 0.001;
    desc_.t_max_ = 1000000000.0;
    desc_.origin_ = ray_.ori_;
    desc_.dir_ = ray_.dir_;
    rayquery_init(rq_, desc_, tlas_);
    rayquery_proceed(rq_);
    hit_ = rayquery_result(rq_);
    if((hit_.kind_ != Ray_Result_Kind_Hit_Mesh_))
    {
        hit_info_.hit_ = false;
        return hit_info_;
    }

    instance_ = scene_.instances_._res_[hit_.instance_idx_];
    mesh_ = scene_.meshes_._res_[instance_.mesh_idx_];
    indices_ = mesh_.indices_;
    base_idx_ = (hit_.primitive_idx_ * 3);
    w_ = ((1.0 - hit_.barycentrics_.x) - hit_.barycentrics_.y);
    n0_ = mesh_.normal_._res_[indices_._res_[(base_idx_ + 0)]];
    n1_ = mesh_.normal_._res_[indices_._res_[(base_idx_ + 1)]];
    n2_ = mesh_.normal_._res_[indices_._res_[(base_idx_ + 2)]];
    normal_ = normalize((((n0_ * w_) + (n1_ * hit_.barycentrics_.x)) + (n2_ * hit_.barycentrics_.y)));
    if(hit_.front_face_)
    {
        normal_ *= (-1.0);
    }

    world_normal_ = normalize((transpose(hit_.world_to_object_) * vec4(normal_.xyz, 0)));
    bary_ = hit_.barycentrics_;
    hit_info_.hit_ = true;
    hit_info_.t_ = hit_.t_;
    hit_info_.normal_ = world_normal_.xyz;
    hit_info_.mesh_idx_ = instance_.mesh_idx_;
    hit_info_.instance_idx_ = hit_.instance_idx_;
    hit_info_.tri_idx_ = hit_.primitive_idx_;
    hit_info_.uv_ = hit_.barycentrics_;
    return hit_info_;
}

Hit_Info ray_skip_alpha_stochastically(Ray start_ray_, Scene scene_, uint tlas_)
{
    Hit_Info hit_ = Hit_Info_ZERO;
    Ray ray_ = Ray_ZERO;
    float t_ = float_ZERO;
    int max_opacity_bounces_ = int_ZERO;
    ray_ = start_ray_;
    t_ = 0.0;
    max_opacity_bounces_ = 100;
    // for construct
    {
        int opacity_bounce_;
        float alpha_;
        for(opacity_bounce_ = 0; (opacity_bounce_ < max_opacity_bounces_); opacity_bounce_ += 1)
        {
            hit_ = ray_scene_intersection(ray_, scene_, tlas_);
            if((!hit_.hit_))
            {
                break;
            }

            t_ += hit_.t_;
            alpha_ = get_alpha(scene_, hit_);
            if(((alpha_ < 1) && (random_f32() >= alpha_)))
            {
                ray_.ori_ = (ray_.ori_ + (ray_.dir_ * hit_.t_));
            }
            else
            {
                break;
break;            }

        }
    }

    hit_.t_ = t_;
    return hit_;
}

float get_alpha(Scene scene_, Hit_Info hit_)
{
    vec4 color_sample_ = vec4_ZERO;
    float alpha_ = float_ZERO;
    color_sample_ = vec4(1);
    if(true)
    {
        Instance instance_;
        Mesh mesh_;
        _res_slice_uint indices_;
        uint base_idx_;
        vec2 uv0_;
        vec2 uv1_;
        vec2 uv2_;
        float w_;
        vec2 texcoords_;
        instance_ = scene_.instances_._res_[hit_.instance_idx_];
        mesh_ = scene_.meshes_._res_[hit_.mesh_idx_];
        indices_ = mesh_.indices_;
        base_idx_ = (hit_.tri_idx_ * 3);
        uv0_ = mesh_.uvs_._res_[indices_._res_[(base_idx_ + 0)]];
        uv1_ = mesh_.uvs_._res_[indices_._res_[(base_idx_ + 1)]];
        uv2_ = mesh_.uvs_._res_[indices_._res_[(base_idx_ + 2)]];
        w_ = ((1.0 - hit_.uv_.x) - hit_.uv_.y);
        texcoords_ = (((uv0_ * w_) + (uv1_ * hit_.uv_.x)) + (uv2_ * hit_.uv_.y));
        if(true)
        {
            color_sample_ = texture_sample(instance_.albedo_tex_, 0, texcoords_);
        }

    }

    alpha_ = color_sample_.a;
    return alpha_;
}

uint hash_u32(uint seed_)
{
    uint x_ = uint_ZERO;
    x_ = seed_;
    x_ = (x_ ^ (x_ >> 17));
    x_ = (x_ * 0xed5ad4bb);
    x_ = (x_ ^ (x_ >> 11));
    x_ = (x_ * 0xac4c1b51);
    x_ = (x_ ^ (x_ >> 15));
    x_ = (x_ * 0x31848bab);
    x_ = (x_ ^ (x_ >> 14));
    return x_;
}

void init_rng(uint global_id_, uint accum_counter_)
{
    uint seed_ = uint_ZERO;
    seed_ = 0;
    RNG_STATE = hash_u32(((global_id_ * 19349663) ^ (accum_counter_ * 83492791)));
}

uint random_u32()
{
    uint result_ = uint_ZERO;
    RNG_STATE = ((RNG_STATE * 747796405) + 2891336453);
    result_ = (((RNG_STATE >> ((RNG_STATE >> 28) + 4)) ^ RNG_STATE) * 277803737);
    result_ = ((result_ >> 22) ^ result_);
    return result_;
}

float random_f32()
{
    uint result_ = uint_ZERO;
    RNG_STATE = ((RNG_STATE * 747796405) + 2891336453);
    result_ = (((RNG_STATE >> ((RNG_STATE >> 28) + 4)) ^ RNG_STATE) * 277803737);
    result_ = ((result_ >> 22) ^ result_);
    return (float(result_) / 4294967295.0);
}

vec2 random_vec2()
{
    float rnd0_ = float_ZERO;
    float rnd1_ = float_ZERO;
    rnd0_ = random_f32();
    rnd1_ = random_f32();
    return vec2(rnd0_, rnd1_);
}

float copysignf(float mag_, float sgn_)
{
    return (((sgn_ > 0)) ? (mag_) : ((-mag_)));
}

mat4 basis_fromz(vec3 v_)
{
    vec3 z_ = vec3_ZERO;
    float sign_ = float_ZERO;
    float a_ = float_ZERO;
    float b_ = float_ZERO;
    vec3 x_ = vec3_ZERO;
    vec3 y_ = vec3_ZERO;
    z_ = normalize(v_);
    sign_ = copysignf(1.0, z_.z);
    a_ = ((-1.0) / (sign_ + z_.z));
    b_ = ((z_.x * z_.y) * a_);
    x_ = vec3((1.0 + (((sign_ * z_.x) * z_.x) * a_)), (sign_ * b_), ((-sign_) * z_.x));
    y_ = vec3(b_, (sign_ + ((z_.y * z_.y) * a_)), (-z_.y));
    return mat4(vec4(x_, 0), vec4(y_, 0), vec4(z_, 0), vec4(0, 0, 0, 0));
}

vec3 sample_hemisphere_cos(vec3 normal_, vec2 ruv_)
{
    float z_ = float_ZERO;
    float r_ = float_ZERO;
    float phi_ = float_ZERO;
    vec3 local_direction_ = vec3_ZERO;
    z_ = sqrt(ruv_.y);
    r_ = sqrt((1 - (z_ * z_)));
    phi_ = ((2 * pi) * ruv_.x);
    local_direction_ = vec3((r_ * cos(phi_)), (r_ * sin(phi_)), z_);
    return normalize((basis_fromz(normal_) * vec4(local_direction_, 0))).xyz;
}

float sample_hemisphere_cos_pdf(vec3 normal_, vec3 direction_)
{
    float cosw_ = float_ZERO;
    cosw_ = dot(normal_, direction_);
    if((cosw_ <= 0))
    {
        return 0;
    }
    else
    {
        return (cosw_ / pi);
return (cosw_ / pi);    }

}

Material_Point get_material_point(Scene scene_, Hit_Info hit_)
{
    vec4 color_sample_ = vec4_ZERO;
    Material_Point mat_point_ = Material_Point_ZERO;
    color_sample_ = vec4(1);
    if(true)
    {
        Instance instance_;
        Mesh mesh_;
        _res_slice_uint indices_;
        uint base_idx_;
        vec2 uv0_;
        vec2 uv1_;
        vec2 uv2_;
        float w_;
        vec2 texcoords_;
        instance_ = scene_.instances_._res_[hit_.instance_idx_];
        mesh_ = scene_.meshes_._res_[hit_.mesh_idx_];
        indices_ = mesh_.indices_;
        base_idx_ = (hit_.tri_idx_ * 3);
        uv0_ = mesh_.uvs_._res_[indices_._res_[(base_idx_ + 0)]];
        uv1_ = mesh_.uvs_._res_[indices_._res_[(base_idx_ + 1)]];
        uv2_ = mesh_.uvs_._res_[indices_._res_[(base_idx_ + 2)]];
        w_ = ((1.0 - hit_.uv_.x) - hit_.uv_.y);
        texcoords_ = (((uv0_ * w_) + (uv1_ * hit_.uv_.x)) + (uv2_ * hit_.uv_.y));
        if(true)
        {
            color_sample_ = texture_sample(instance_.albedo_tex_, 0, texcoords_);
        }

    }

    mat_point_.color_ = color_sample_.rgb;
    return mat_point_;
}

vec3 sample_matte(vec3 normal_, vec2 rn_)
{
    return sample_hemisphere_cos(normal_, rn_);
}

vec3 eval_matte(vec3 color_, vec3 normal_, vec3 incoming_)
{
    return ((color_ / pi) * abs(dot(normal_, incoming_)));
}

float sample_matte_pdf(vec3 normal_, vec3 incoming_)
{
    return sample_hemisphere_cos_pdf(normal_, incoming_);
}

bool is_finite(vec3 v_)
{
    bool is_x_finite_ = bool_ZERO;
    bool is_y_finite_ = bool_ZERO;
    bool is_z_finite_ = bool_ZERO;
    is_x_finite_ = ((floatBitsToInt(v_.x) & 0x7F800000) != 0x7F800000);
    is_y_finite_ = ((floatBitsToInt(v_.y) & 0x7F800000) != 0x7F800000);
    is_z_finite_ = ((floatBitsToInt(v_.z) & 0x7F800000) != 0x7F800000);
    return ((is_x_finite_ && is_y_finite_) && is_z_finite_);
}

float sun_disk_falloff(vec3 ray_dir_, vec3 sun_dir_, float angular_radius_)
{
    float cos_theta_ = float_ZERO;
    float cos_inner_ = float_ZERO;
    float cos_outer_ = float_ZERO;
    cos_theta_ = dot(ray_dir_, sun_dir_);
    cos_inner_ = cos(angular_radius_);
    cos_outer_ = cos((angular_radius_ * 1.5));
    return smoothstep(cos_outer_, cos_inner_, cos_theta_);
}

vec3 sample_sun_direction(vec3 sun_dir_, float angular_radius_, vec2 u_)
{
    float cos_theta_max_ = float_ZERO;
    float cos_theta_ = float_ZERO;
    float sin_theta_ = float_ZERO;
    float phi_ = float_ZERO;
    vec3 t_ = vec3_ZERO;
    vec3 b_ = vec3_ZERO;
    cos_theta_max_ = cos(angular_radius_);
    cos_theta_ = mix(1.0, cos_theta_max_, u_.x);
    sin_theta_ = sqrt((1.0 - (cos_theta_ * cos_theta_)));
    phi_ = ((2.0 * pi) * u_.y);
    if((abs(sun_dir_.z) < 0.999))
    {
        t_ = normalize(cross(sun_dir_, vec3(0.0, 0.0, 1.0)));
    }
    else
    {
        t_ = normalize(cross(sun_dir_, vec3(0.0, 1.0, 0.0)));
t_ = normalize(cross(sun_dir_, vec3(0.0, 1.0, 0.0)));    }

    b_ = cross(sun_dir_, t_);
    return (((t_ * (cos(phi_) * sin_theta_)) + (b_ * (sin(phi_) * sin_theta_))) + (sun_dir_ * cos_theta_));
}

float eval_sun_pdf(vec3 dir_, vec3 sun_dir_, float angular_radius_)
{
    float cos_theta_ = float_ZERO;
    float cos_max_ = float_ZERO;
    float solid_angle_ = float_ZERO;
    cos_theta_ = dot(dir_, sun_dir_);
    cos_max_ = cos(angular_radius_);
    if((cos_theta_ < cos_max_))
    {
        return 0;
    }

    solid_angle_ = ((2 * pi) * (1 - cos_max_));
    return (1 / solid_angle_);
}

vec3 sample_lights(Lights lights_, vec3 pos_, vec3 normal_, vec3 outgoing_)
{
    vec3 light_dir_ = vec3_ZERO;
    light_dir_ = sample_sun_direction((-lights_.dir_light_dir_), lights_.dir_light_angle_, random_vec2());
    if((dot(light_dir_, normal_) < 0))
    {
        return vec3(0);
    }

    return light_dir_;
}

float sample_lights_pdf(Lights lights_, vec3 pos_, vec3 incoming_)
{
    return eval_sun_pdf(incoming_, (-lights_.dir_light_dir_), lights_.dir_light_angle_);
}

vec3 sample_sky_emission(vec3 dir_, Scene scene_)
{
    vec3 emission_ = vec3_ZERO;
    emission_ = (sun_disk_falloff(dir_, (-scene_.lights_.dir_light_dir_), scene_.lights_.dir_light_angle_) * scene_.lights_.dir_light_emission_);
    emission_ += vec3(0.67, 0.76, 1.00);
    return emission_;
}

vec3 clamp_radiance(vec3 radiance_)
{
    vec3 res_ = vec3_ZERO;
    float max_radiance_ = float_ZERO;
    res_ = radiance_;
    if((!is_finite(res_)))
    {
        res_ = vec3(0.0);
    }

    max_radiance_ = 100.0;
    if((((res_.x > max_radiance_) || (res_.y > max_radiance_)) || (res_.z > max_radiance_)))
    {
        res_ *= (max_radiance_ / max(res_.x, max(res_.y, res_.z)));
    }

    return res_;
}

