/*
Copyright(c) 2016-2024 Panos Karabelas

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and / or sell
copies of the Software, and to permit persons to whom the Software is furnished
to do so, subject to the following conditions :

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/

// = INCLUDES ========
#include "common.hlsl"
#include "fog.hlsl"
//====================

struct translucency
{
    struct refraction
    {
        static float compute_fade_factor(float2 uv)
        {
            float edge_threshold = 0.05f; // how close to the edge to start fading
            float2 edge_distance = min(uv, 1.0f - uv);
            return saturate(min(edge_distance.x, edge_distance.y) / edge_threshold);
        }
        
        static float3 refract_vector(float3 i, float3 n, float eta)
        {
            float cosi  = dot(-i, n);
            float cost2 = 1.0f - eta * eta * (1.0f - cosi * cosi);
            return eta * i + (eta * cosi - sqrt(abs(cost2))) * n;
        }
        
        static float3 get_color(Surface surface)
        {
            const float scale = 0.05f;
            
            // comute view space data
            float3 view_pos    = world_to_view(surface.position);
            float3 view_normal = world_to_view(surface.normal, false);
            float3 view_dir    = normalize(view_pos);
            
            // compute refracted uv
            float3 refracted_dir        = refract_vector(view_dir, view_normal, 1.0f / surface.ior);
            float2 refraction_uv_offset = refracted_dir.xy * scale;
            float2 refracted_uv         = surface.uv + refraction_uv_offset;
    
            // get base color (no refraction)
            float frame_mip_count = pass_get_f3_value().x;
            float mip_level       = lerp(0, frame_mip_count, surface.roughness_alpha);
            float3 color          = tex_frame.SampleLevel(samplers[sampler_trilinear_clamp], surface.uv, mip_level).rgb;
            
            // dont refract surfaces which are behind this surface
            const bool is_behind = get_linear_depth(surface.depth) < get_linear_depth(refracted_uv);
            if (is_behind)
            {
                // simulate light breaking off into individual color bands via chromatic aberration
                float3 color_refracted = 0.0f;
                {
                    float chromatic_aberration_strength  = surface.ior * 0.0005f;
                    chromatic_aberration_strength       *= (1.0f + surface.roughness_alpha);
                    
                    float2 ca_offsets[3];
                    ca_offsets[0] = float2(chromatic_aberration_strength, 0.0f);
                    ca_offsets[1] = float2(0.0f, 0.0f);
                    ca_offsets[2] = float2(-chromatic_aberration_strength, 0.0f); 
        
                    [unroll]
                    for (int i = 0; i < 3; ++i)
                    {
                        float4 sampled_color = tex_frame.SampleLevel(samplers[sampler_trilinear_clamp], refracted_uv + ca_offsets[i], mip_level);
                        color_refracted[i] = sampled_color[i];
                    }
                }
        
                // screen fade
                float fade_factor = compute_fade_factor(refracted_uv);
                color             = lerp(color, color_refracted, fade_factor);
            }
    
            return color;
        }
    };
    
    struct water
    {
        static float4 get_color(Surface surface)
        {
            // color spectrum light absorption
            const float3 light_absorption = float3(0.3f, 0.2f, 0.1f);

            // compute depth
            float water_level       = get_position(surface.uv).y;
            float water_floor_level = get_position(get_depth_opaque(surface.uv), surface.uv).y;
            float water_depth       = max(water_level - water_floor_level, 0.0f);

            // compute color and alpha at that depth
            float3 color = float3(exp(-light_absorption.x * water_depth), exp(-light_absorption.y * water_depth), exp(-light_absorption.z * water_depth));
            float alpha  = 1.0f - exp(-water_depth * 0.2f);

            return float4(color, alpha);
        }
    };
};

[numthreads(THREAD_GROUP_COUNT_X, THREAD_GROUP_COUNT_Y, 1)]
void mainCS(uint3 thread_id : SV_DispatchThreadID)
{
    if (any(int2(thread_id.xy) >= pass_get_resolution_out()))
        return;

    Surface surface;
    surface.Build(thread_id.xy, true, false);

    bool early_exit_1 = pass_is_opaque() && surface.is_transparent(); // if this is an opaque pass, ignore all transparent pixels.
    bool early_exit_2 = pass_is_transparent() && surface.is_opaque(); // if this is a transparent pass, ignore all opaque pixels.
    bool early_exit_3 = pass_is_transparent() && surface.is_sky();    // if this is a transparent pass, ignore sky pixels (they only render in the opaque)
    if (early_exit_1 || early_exit_2 || early_exit_3)
        return;

    float4 color = float4(0.0f, 0.0f, 0.0f, surface.alpha); // maintain surface alpha, in case FSR benefits when generating the masks

    // volumetric fog/light
    color.rgb += tex_light_volumetric[thread_id.xy].rgb;
    
    // sky
    if (surface.is_sky()) 
    {
        color.rgb += tex_environment.SampleLevel(samplers[sampler_bilinear_clamp], direction_sphere_uv(surface.camera_to_pixel), 0).rgb;
        color.a    = 1.0f;
    }
    else // anything else
    {
        // get light samples
        float3 light_diffuse  = tex_light_diffuse[thread_id.xy].rgb;
        float3 light_specular = tex_light_specular[thread_id.xy].rgb;

        // refraction
        float3 light_transparent = 0.0f;
        if (surface.is_transparent())
        {
            // refraction
            light_transparent = translucency::refraction::get_color(surface);

            // water light penetration
            if (surface.is_water())
            {
                float4 light_water    = translucency::water::get_color(surface);
                light_transparent.rgb = lerp(light_transparent.rgb, light_water.rgb, light_water.a);
                color.a               = light_water.a;
            }
        }
        
        // compose
        float3 light  = (light_diffuse + surface.gi) * surface.albedo + light_specular;
        color.rgb    += lerp(light, light_transparent, 1.0f - color.a);

        // fog
        color.rgb += got_fog_radial(surface.position, buffer_frame.camera_position.xyz);
    }

    tex_uav[thread_id.xy] = saturate_16(color);
}
