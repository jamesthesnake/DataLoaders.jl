abstract type BatchDim end

struct BatchDimFirst <: BatchDim end
struct BatchDimLast <: BatchDim end

"""
    BatchViewCollated(data, size; droplast = false)

A batch view of container `data` with collated batches of
size `size`.
"""
@with_kw_noshow struct BatchViewCollated{TData}
    data::TData
    size::Int
    count::Int
    partial::Bool
    batchdim::BatchDim = BatchDimLast()
end

Base.show(io::IO, bvcollated::BatchViewCollated) = print(io, "batchviewcollated() with $(bvcollated.count) batches of size $(bvcollated.size)")

const batchviewcollated = BatchViewCollated

function BatchViewCollated(data, size; partial = true, batchdim = BatchDimLast())
    count = nobs(data) ÷ size
    if partial && (nobs(data) % size > 0)
        count += 1
    end
    return BatchViewCollated(data, size, count, partial, batchdim)
end

Base.length(bv::BatchViewCollated) = bv.count
LearnBase.nobs(bv::BatchViewCollated) = length(bv)

function LearnBase.getobs(bv::BatchViewCollated, idx::Int)
    idxs = batchindices(nobs(bv.data), bv.size, idx)
    collate([getobs(bv.data, idx) for idx in idxs])
end

function LearnBase.getobs!(buf, bv::BatchViewCollated, idx::Int)
    indices = batchindices(nobs(bv.data), bv.size, idx)
    for (idx, obs) in zip(indices, obsslices(buf, bv.batchdim))
        obs_ = getobs!(obs, bv.data, idx)
        # if data container does not implement, getobs!, this is needed
        if obs_ !== obs
            copyrec!(obs, obs_)
        end
    end

    if bv.partial && (idx == nobs(bv)) && (nobs(bv.data) % bv.size > 0)
        # This will mess up the buffer in the `RingBuffer`
        # by not reinserting the correct buffer.
        # It is okay only because it will that buffer will
        # not be used since the partial batch is the last
        # batch.
        return obsslice(buf, 1:(nobs(bv.data) % bv.size), bv.batchdim)
    end


    return buf
end


# batch view helpers

"""
    obsslices(batch, batchdim = BatchDimLast())

Iterate over views of all observations in a `batch`.
`batch` can be a batched array, a tuple of batches, or a
dict of batches.

```julia
batch = rand(10, 10, 4)  # batch size is 4
iter = obsslices(batch, BatchDimLast())
@assert size(first(iter)) == (10, 10)

iter2 = obsslices(batch, BatchDimFirst())
@assert size(first(iter)) == (10, 4)
```
"""
obsslices(batch, batchdim = BatchDimLast()) =
    (obsslice(batch, i, batchdim) for i in 1:_batchsize(batch, batchdim))

function obsslice(batch::AbstractArray{T, N}, i, ::BatchDimLast) where {T, N}
    return view(batch, [(:) for _ in 1:N-1]..., i)
end

function obsslice(batch::AbstractArray{T, N}, i, ::BatchDimFirst) where {T, N}
    return view(batch, i, [(:) for _ in 2:N]...)
end

function obsslice(batch::Tuple, i, batchdim)
    return Tuple(obsslice(batch[j], i, batchdim) for j in 1:length(batch))
end

function obsslice(batch::NamedTuple, i, batchdim)
    return (; zip(keys(batch), obsslice(values(batch), i, batchdim))...)
end

function obsslice(batch::Dict, i, batchdim)
    return Dict(k => obsslice(v, i, batchdim) for (k, v) in batch)
end

# Utils

_batchsize(batch::Union{Tuple,NamedTuple}, batchdim) = _batchsize(batch[1], batchdim)
_batchsize(batch::Dict, batchdim) = _batchsize(batch[first(keys(batch))], batchdim)
_batchsize(batch::AbstractArray{T, N}, ::BatchDimLast) where {T, N} = size(batch, N)
_batchsize(batch::AbstractArray, ::BatchDimFirst) = size(batch, 1)

copyrec!(dst::AbstractArray, src::AbstractArray) = copy!(dst, src)
copyrec!(dst::Tuple, src::Tuple) = foreach((a, b) -> copyrec!(a, b), dst, src)
copyrec!(dst::NamedTuple, src::NamedTuple) = copyrec!(values(dst), values(src))
copyrec!(dst::Dict, src::Dict) = foreach((a, b) -> copyrec!(dst, src), values(dst), values(src))

"""
    batchindices(n, size, i)

Get the indices of batch `i` with batch size `size` of
a collection with `n` elements.

Might be a partial batch if `i` is the last batch and
`n` is not divisible by `size`.
"""
function batchindices(n, size::Int, i::Int)
    from = (i - 1) * size + 1
    to = min(n, from + size - 1)
    return from:to
end
