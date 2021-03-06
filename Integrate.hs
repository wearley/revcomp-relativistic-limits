{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}

module Integrate where
import Data.Complex (Complex((:+)))

import Stream
import Vector
import Helper

{---

A suite of integration tools.

Given a differential equation system in the appropriate form,
    dy/dt = f(t;x(t),y(t))    y(t0) = y0
where y can be a vector or other module-like object and x is an auxiliary
function, the routines return a 'stream' object that can be used to
efficiently extract values of y at various values of t:
    stream_y = dsolve f t0 stream_x y0

See Stream for guidance on how to manipulate and read streams.

Three integration routines are provided,
 - Euler,
 - Runge-Kutta (4th order, non-adaptive),
 - Dopri5 (5(4)th order, adaptive step size).
dsolve defaults to Dopri5.

The primed routines (e.g. dsolve') dispense with the auxiliary function x:
    dy/dt = f(t;y(t))
    stream_y = dsolve f t0 y0

Whilst the integration routines below support complex integrands, the
independent variable (e.g. t) is taken along the real line. Nevertheless,
this is still general as all integrations occur along 1D paths, and so
we have not lost any generality. If one wishes to integrate along a path
in the complex plane (or indeed some other scalar domain), one can use
these routines by simply parameterising the desired path u by the
independent variable t. If the integrand is f, then the new integrand g is
    g(x,y;t) = f(x,y;t) * du/dt
The start and end points (and intermediate points) should be specified
by the parameter t.

It makes sense to enforce this manual parameterisation because specifying
a path involves finding u(t) anyway, and we can't integrate to any arbitrary
point z -- rather, we can only integrate to points along the path u, and we
cannot easily ascertain whether there even exists a point t such that u(t) = z.
Therefore, we let the user deal with this.

---}

type Integrand x y = Double -> x -> y -> y
type Integrator' x y o = Integrand x y -> Double -> StreamFD x -> y -> o
type Integrator x y = Integrator' x y (StreamFD y)

type SimpleIntegrand y = Double -> y -> y
type SimpleIntegrator y = SimpleIntegrand y -> Double -> y -> StreamFD y

type StepFunction x y s = Integrand x y -> s -> s

simpleIntegrator :: Integrator x y -> SimpleIntegrator y
simpleIntegrator int f t0 = int (\t _ -> f t) t0 sbot

inan :: CVector v => Stream t v
inan = sconst (vconst (0/0)) bottom

---

euler :: CVector y => Double -> Integrator x y
euler h f t0 x0 y0 t1
  | isNaN (dt + h + cnorm1 y1) = inan
  | abs h >= abs dt = Stream y1 $ euler h f t1 x' y1
  | otherwise       = euler h f (t0+h') x' (y' h') t1
  where
    dt = t1 - t0
    y1 = y' dt

    Stream x x' = x0 t0
    y' = cperturb y0 (f t0 x y0)
    h' = if t1 > t0 then abs h else -(abs h)

euler' :: CVector y => Double -> SimpleIntegrator y
euler' = simpleIntegrator . euler

---

type RK4Step x y = (Double, StreamFD x, y)

stepRK4 :: CVector y => Double -> StepFunction x y (RK4Step x y)
stepRK4 h f (t0,xf,y0) = (t2,xg,y2)
  where
    t1 = t0 + 0.5*h
    t2 = t0 + h
    (xg, [x0,x1,x2]) = spops' xf [t0,t1,t2]

    k1 = cscale h $ f t0 x0 (y0)
    k2 = cscale h $ f t1 x1 (vperturb y0 k1 0.5)
    k3 = cscale h $ f t1 x1 (vperturb y0 k2 0.5)
    k4 = cscale h $ f t2 x2 (vplus y0 k3)

    y2 = cperturb y0 (vsum [k1,k2,k2,k3,k3,k4]) (1/6)

rk4 :: CVector y => Double -> Integrator x y
rk4 h f t0 x0 y0 t1
  | isNaN (dt + h + cnorm1 y'') = inan
  | abs h >= abs dt = Stream y'' $ rk4 h f t'' x'' y''
  | otherwise       = rk4 h f t' x' y' t1
  where
    dt = t1 - t0
    (t', x', y')  = stepRK4 h  f (t0,x0,y0)
    (t'',x'',y'') = stepRK4 dt f (t0,x0,y0)

rk4' :: CVector y => Double -> SimpleIntegrator y
rk4' = simpleIntegrator . rk4

---

data StepControl v = StepControl
                   { atol :: v
                   , rtol :: v
                   , clipFac :: Double -> Double
                   , clipFac' :: Double -> Double
                   , clipStep :: Double -> Double -> Double
                   }

defaultSC :: CVector y => StepControl y
defaultSC = StepControl
          { atol = vconst 1e-16
          , rtol = vconst 1e-16
          , clipFac  = clipper 0.1 5
          , clipFac' = clipper 0.1 1
          , clipStep = defaultClipStep 10
          }

rknorm :: CVector y => StepControl y -> y -> y -> Double
rknorm c y e = cmean2 $ vzip (/) e sc
  where sc = atol c `vplus` (rtol c `vhprod` vmap abs y)

--- Solving ODEs I - Nonstiff Problems :: II.4, II.5
---  -- Hairer, Nørsett, Wanner

type DOPRI5Step x y = (Double, Double, StreamFD x, y)

stepDOPRI5 :: CVector y => StepControl y -> StepFunction x y (DOPRI5Step x y)
stepDOPRI5 c f (h0,t1,xf,y1) =
    if err <= 1 then                 (h',t6,xg,y7)
                else stepDOPRI5 c' f (h',t1,xf,y1)
  where
    h = clipStep c t1 h0
    [t2,t3,t4,t5,t6] = map ((t1+) . (h*)) [0.2,0.3,0.8,8/9,1]
    (xg, [x1,x2,x3,x4,x5,x6]) = spops' xf [t1,t2,t3,t4,t5,t6]

    k1 = f' t1 x1 $ y1
    k2 = f' t2 x2 $ cperturb y1 k1 (1/5)
    -- k1 = f' t1 x1 $ y' []
    -- k2 = f' t2 x2 $ y' [1/5]
    k3 = f' t3 x3 $ y' [3/40, 9/40]
    k4 = f' t4 x4 $ y' [44/45, -56/15, 32/9]
    k5 = f' t5 x5 $ y' [19372/6561, -25360/2187, 64448/6561, -212/729]
    k6 = f' t6 x6 $ y' [9017/3168, -355/33, 46732/5247, 49/176, -5103/18656]
    k7 = f' t6 x6 $ y7

    y7 = y' [35/384, 0, 500/1113, 125/192, -2187/6784, 11/84]
    dy7 = dy' [-71/57600, 0, 71/16695, -71/1920, 17253/339200, -22/525, 1/40]

    err = rknorm c (vzip go y1 y7) dy7
      where go x y | cabs x > cabs y = abs x
                   | otherwise       = abs y
    fac = (0.38 / err) ** 0.2
    h' = h * clipFac c fac
    c' = c { clipFac = clipFac' c }

    f' t x y = cscale h $ f t x y
    y' = vplus y1 . dy'
    dy' ws = vlc' ws [k1,k2,k3,k4,k5,k6,k7]

initialStep :: CVector y => StepControl y -> Integrator' x y Double
initialStep c f t0 xf y0 = min (100 * h0) h1
  where
    Stream x0 xg = xf t0
    y0' = f t0 x0 y0

    d0 = rknorm c y0 y0
    d1 = rknorm c y0 y0'
    h0 = if d0 < 1e-5 || d1 < 1e-5 then 0.01 * (d0/d1) else 1e-6

    t1 = t0 + h0
    y1 = cperturb y0 y0' h0
    Stream x1 xh = xg t1
    y1' = f t1 x1 y1

    d2 = rknorm c y0 (vsub y1' y0') / h0
    h1 = if d1 <= 1e-15 && d2 <= 1e-15
            then max 1e-6 (h0*1e-3)
            else (0.01 / max d1 d2) ** 0.2

dopri5 :: CVector y => StepControl y -> Integrator x y
dopri5 c f t0 x0 y0 = dopri5h c h0 f t0 x0 y0
  where h0 = initialStep c f t0 x0 y0

dopri5h :: CVector y => StepControl y -> Double -> Integrator x y
dopri5h c h f t x y t'
  | isNaN (dt + hmin + cnorm1 y') = inan
  | abs dt < abs hmin = s
  | otherwise =
        let (h'',t'',x'',y'') = stepDOPRI5 c f (h',t,x,y)
            o = compare t'' t'
            o' = compare t' t''
        in case (if t < t' then o else o') of
            LT -> dopri5h c h'' f t'' x'' y'' t'
            EQ -> Stream y'' $ dopri5h c h'' f t'' x'' y''
            GT -> s
  where
    dt = t' - t
    h' = signum dt * (min (abs h) (abs dt))
    hmin = clipStep c t dt

    -- small step
    (_,_,y') = stepRK4 dt f (t,x,y)
    s = Stream y' $ dopri5h c h' f t x y

dopri5' :: CVector y => StepControl y -> SimpleIntegrator y
dopri5' = simpleIntegrator . dopri5

--- default integrators

dsolve :: CVector y => Integrator x y
dsolve = dopri5 defaultSC

dsolve' :: CVector y => SimpleIntegrator y
dsolve' = dopri5' defaultSC

--- pure integration

integrate :: CVector y => (Double -> x -> y) -> StreamFD x
                       -> Double -> Double -> y
integrate  f x a = sget (dsolve g a x    (vconst 0))
  where g = (const .) . f

integrate' :: CVector y => (Double -> y) -> Double -> Double -> y
integrate' f   a = sget (dsolve g a sbot (vconst 0))
  where g = const . const . f

pathIntegral' :: CVector' y => (VField y -> y) -> (VField y -> VField y)
                            -> VField y -> Double -> Double -> y
pathIntegral' f u' u0 a = fst . sget (dsolve g a sbot (vconst 0, u0))
  where g t x (y,u) = let du = u' (ccoerce t) in (vscale du (f u), du)

lineIntegral' :: CVector' y => (VField y -> y) -> VField y -> VField y -> y
lineIntegral' f u0 u1 = pathIntegral' f (const du) u0 0 dt
  where dt = cabs (u1 - u0)
        du = (u1 - u0) / (ccoerce dt)

linesIntegral' :: CVector' y => (VField y -> y) -> [VField y] -> y
linesIntegral' f us = vsum $ zipWith (lineIntegral' f) us (tail us)

polyIntegral' :: CVector' y => (VField y -> y) -> [VField y] -> y
polyIntegral' f us = vsum $ zipWith (lineIntegral' f) us us'
  where us' = tail us ++ [head us]

residue'square :: (CVector' y, VField y ~ Complex a, Num a)
                  => (VField y -> y) -> Complex a -> a -> y
residue'square f u0 r = polyIntegral' f (map (u0+) dirs)
  where dirs = [r:+(-r), r:+r, (-r):+r, (-r):+(-r)]

residue'circ :: (CVector' y, VField y ~ Complex a, RealFloat a)
                => (VField y -> y) -> Complex a -> a -> y
residue'circ f u0 r = pathIntegral' f u' (u0+(r:+0)) 0 (2*pi)
  where u' t = (0:+r) * exp((0:+1) * t)

residue' :: (CVector' y, VField y ~ Complex a, RealFloat a)
            => (VField y -> y) -> Complex a -> a -> y
residue' = residue'square