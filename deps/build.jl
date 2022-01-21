# copied from CUDAdrv/deps/build.jl

using Libdl
use_artifacts = !parse(Bool, get(ENV, "JULIA_AMDGPU_DISABLE_ARTIFACTS", "false"))

function version_hsa(libpath)
    lib = Libdl.dlopen(libpath)
    sym = Libdl.dlsym(lib, "hsa_system_get_info")
    major_ref = Ref{Cushort}(typemax(Cushort))
    minor_ref = Ref{Cushort}(typemax(Cushort))
    status = ccall(sym, Cint, (Cint, Ptr{Cushort}), 0, major_ref)
    if status != 0
        @warn "HSA error: $status"
        return v"0"
    end
    status = ccall(sym, Cint, (Cint, Ptr{Cushort}), 1, minor_ref)
    if status != 0
        @warn "HSA error: $status"
        return v"0"
    end
    return VersionNumber(major_ref[], minor_ref[])
end

function init_hsa(libpath)
    lib = Libdl.dlopen(libpath)
    sym = Libdl.dlsym(lib, "hsa_init")
    ccall(sym, Cint, ())
end

function shutdown_hsa(libpath)
    lib = Libdl.dlopen(libpath)
    sym = Libdl.dlsym(lib, "hsa_shut_down")
    ccall(sym, Cint, ())
end

## auxiliary routines

status = 0
function build_warning(reason)
    println("$reason.")
    global status
    status = 1
end

function build_error(reason)
    println(reason)
    exit(1)
end

## library finding

function find_roc_paths()
    paths = split(get(ENV, "LD_LIBRARY_PATH", ""), ":")
    paths = filter(path->path != "", paths)
    paths = map(Base.Filesystem.abspath, paths)
    push!(paths, "/opt/rocm/hsa/lib") # shim for Ubuntu rocm packages...
    paths = filter(isdir, paths)
    @show paths
    return paths
end

function find_hsa_library(lib, dirs)
    path = Libdl.find_library(lib)
    if path != ""
        return Libdl.dlpath(path)
    end
    for dir in dirs
        files = readdir(dir)
        for file in files
            @info "$file: $(basename(file) == lib * ".so.1")"
            if basename(file) == lib * ".so.1"
                return joinpath(dir, file)
            end
        end
    end
end

function find_ld_lld()
    paths = split(get(ENV, "PATH", ""), ":")
    paths = filter(path->path != "", paths)
    paths = map(Base.Filesystem.abspath, paths)
    basedir = get(ENV, "ROCM_PATH", "/opt/rocm")
    ispath(joinpath(basedir, "llvm/bin/ld.lld")) &&
        push!(paths, joinpath(basedir, "llvm/bin/"))
    ispath(joinpath(basedir, "hcc/bin/ld.lld")) &&
        push!(paths, joinpath(basedir, "/hcc/bin/"))
    ispath(joinpath(basedir, "opencl/bin/x86_64/ld.lld")) &&
        push!(paths, joinpath(basedir, "opencl/bin/x86_64/"))
    for path in paths
        exp_ld_path = joinpath(path, "ld.lld")
        if ispath(exp_ld_path)
            try
                tmpfile = mktemp()
                run(pipeline(`$exp_ld_path -v`; stdout=tmpfile[1]))
                vstr = read(tmpfile[1], String)
                rm(tmpfile[1])
                vstr = replace(vstr, "AMD " => "")
                vstr_splits = split(vstr, ' ')
                if VersionNumber(vstr_splits[2]) >= v"6.0.0"
                    @info "Found useable ld.lld at $exp_ld_path"
                    return exp_ld_path
                end
            catch
                @warn "Failed running ld.lld in $exp_ld_path"
            end
        end
    end
    return ""
end

function find_roc_library(name::String)
    lib = Libdl.find_library(Symbol(name))
    lib == "" && return nothing
    return Libdl.dlpath(lib)
end

## main

const config_path = joinpath(@__DIR__, "ext.jl")
const previous_config_path = config_path * ".bak"

function write_ext(config, path)
    open(path, "w") do io
        println(io, "# autogenerated file, do not edit")
        for (key,val) in config
            println(io, "const $key = $(repr(val))")
        end
    end
end


function main()
    ispath(config_path) && mv(config_path, previous_config_path; force=true)
    config = Dict{Symbol,Any}(
        :configured => false,
        :build_reason => "unknown",
        :lld_configured => false,
        :lld_build_reason => "unknown",
        :hsa_configured => false,
        :hsa_build_reason => "unknown",
        :hip_configured => false,
        :hip_build_reason => "unknown",
        :device_libs_configured => false,
        :device_libs_build_reason => "unknown",
        :librocblas => nothing,
        :librocsparse => nothing,
        :librocalution => nothing,
        :librocfft => nothing,
        :librocrand => nothing,
        :libmiopen => nothing,
    )
    write_ext(config, config_path)

    # Skip build if running under AutoMerge
    if get(ENV, "JULIA_REGISTRYCI_AUTOMERGE", "false") == "true"
        exit(0)
    end

    ## discover stuff

    # check that we're running Linux
    if !Sys.islinux()
        build_warning("Not running Linux, which is the only platform currently supported by the ROCm Runtime.")
        config[:build_reason] = "Unsupported OS: $(repr(Sys.KERNEL))"
        write_ext(config, config_path)
        return
    end

    # find some paths for library search
    roc_dirs = find_roc_paths()

    ### Find HSA
    libhsaruntime_path = nothing
    if use_artifacts
        try
            @eval using hsa_rocr_jll
        catch err
            iob = IOBuffer()
            println(iob, "`using hsa_rocr_jll` failed:")
            Base.showerror(iob, err)
            Base.show_backtrace(iob, catch_backtrace())
            config[:hsa_build_reason] = String(take!(iob))
            write_ext(config, config_path)
            return
        end
        libhsaruntime_path = hsa_rocr_jll.libhsa_runtime64
    else
        libhsaruntime_path = find_hsa_library("libhsa-runtime64.so.1", roc_dirs)
    end
    if libhsaruntime_path === nothing
        build_warning("Could not find HSA runtime library v1")
        config[:hsa_build_reason] = "HSA runtime library v1 not found"
        write_ext(config, config_path)
        return
    end

    # initializing the library isn't necessary, but flushes out errors that otherwise would
    # happen during `version` or, worse, at package load time.
    status = init_hsa(libhsaruntime_path)
    if status != 0
        build_warning("Initializing HSA runtime failed with code $status.")
        config[:hsa_build_reason] = "Failed to initialize HSA runtime, status code: $status"
        write_ext(config, config_path)
        return
    end

    libhsaruntime_version = version_hsa(libhsaruntime_path)

    # also shutdown just in case
    status = shutdown_hsa(libhsaruntime_path)
    if status != 0
        build_warning("Shutdown of HSA runtime failed with code $status.")
        config[:hsa_build_reason] = "Failed to shutdown HSA runtime, status code: $status"
        write_ext(config, config_path)
        return
    end
    config[:libhsaruntime_path] = libhsaruntime_path
    config[:libhsaruntime_version] = libhsaruntime_version
    config[:hsa_configured] = true

    ### Find HIP
    libhip_path = nothing
    if use_artifacts
        try
            @eval using HIP_jll
        catch err
            iob = IOBuffer()
            println(iob, "`using HIP_jll` failed:")
            Base.showerror(iob, err)
            Base.show_backtrace(iob, catch_backtrace())
            config[:hip_build_reason] = String(take!(iob))
            write_ext(config, config_path)
            return
        end
        libhip_path = HIP_jll.libamdhip64
    else
        libhip_path = Libdl.find_library(["libamdhip64", "libhip_hcc"])
    end
    if libhip_path === nothing
        build_warning("Could not find HIP runtime library")
        config[:hip_build_reason] = "HIP runtime library not found"
        write_ext(config, config_path)
        return
    end
    config[:libhip_path] = libhip_path
    config[:hip_configured] = true

    ### Find ld.lld
    ld_path = find_ld_lld()
    if ld_path == ""
        build_warning("Could not find ld.lld, please install it with your package manager")
        config[:lld_build_reason] = "ld.lld executable not found"
        write_ext(config, config_path)
        return
    end
    config[:ld_lld_path] = ld_path
    config[:lld_configured] = true

    ### Find/download device-libs
    device_libs_path = nothing
    device_libs_downloaded = nothing
    if use_artifacts
        try
            @eval using ROCmDeviceLibs_jll
        catch err
            iob = IOBuffer()
            println(iob, "`using ROCmDeviceLibs_jll` failed:")
            Base.showerror(iob, err)
            Base.show_backtrace(iob, catch_backtrace())
            config[:device_libs_build_reason] = String(take!(iob))
            write_ext(config, config_path)
            return
        end
        device_libs_path = ROCmDeviceLibs_jll.bitcode_path
        device_libs_downloaded = false
    else
        #include("download_device_libs.jl")
        device_libs_path = "/opt/rocm/amdgcn/bitcode"
        device_libs_downloaded = true
    end
    config[:device_libs_path] = device_libs_path
    config[:device_libs_downloaded] = device_libs_downloaded
    config[:device_libs_configured] = true

    ### Find external HIP-based libraries
    for name in ("rocblas", "rocsparse", "rocalution", "rocfft", "rocrand", "MIOpen")
        lib = Symbol("lib$(lowercase(name))")
        config[lib] = find_roc_library("lib$name")
        if config[lib] === nothing
            build_warning("Could not find library '$name'")
            # TODO: Save build reason?
        end
    end

    config[:configured] = true

    ## (re)generate ext.jl

    function globals(mod)
        all_names = names(mod, all=true)
        filter(name-> !any(name .== [nameof(mod), Symbol("#eval"), :eval]), all_names)
    end

    if isfile(previous_config_path)
        @eval module Previous; include($previous_config_path); end
        previous_config = Dict{Symbol,Any}(name => getfield(Previous, name)
                                           for name in globals(Previous))

        if config == previous_config
            mv(previous_config_path, config_path; force=true)
            return
        end
    end

    write_ext(config, config_path)

    if status != 0
        # we got here, so the status is non-fatal
        build_warning("""

            AMDGPU.jl has been built successfully, but there were warnings.
            Some functionality may be unavailable.""")
    end
end

# Load HSA, HIP, and friends, and ROCm external libraries
main()
